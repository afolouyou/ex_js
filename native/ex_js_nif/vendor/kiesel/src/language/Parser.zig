const ptk = @import("ptk");
const std = @import("std");

const build_options = @import("build-options");
const ast = @import("ast.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

const Diagnostics = @import("Diagnostics.zig");
const NewToken = @import("Token.zig");
const NewTokenizer = @import("Tokenizer.zig");
const String = types.String;
const TemporaryChange = utils.TemporaryChange;
const containsSlice = utils.containsSlice;
const findLineTerminator = NewTokenizer.findLineTerminator;
const temporaryChange = utils.temporaryChange;

const Parser = @This();

allocator: std.mem.Allocator,
core: ParserCore,
diagnostics: *Diagnostics,
state: State = .{},
identifier_stack: std.ArrayList(ast.Identifier),

pub const State = struct {
    in_async_function: bool = false,
    in_breakable_statement: bool = false,
    in_class_body: bool = false,
    in_class_constructor: bool = false,
    in_class_static_block: bool = false,
    in_default_export: bool = false,
    in_formal_parameters: bool = false,
    in_function_body: bool = false,
    in_generator_function: bool = false,
    in_iteration_statement: bool = false,
    in_labelled_statement: bool = false,
    in_method_definition: bool = false,
    in_module: bool = false,
    new_target_allowed: bool = false,
    in_strict_mode: bool = false,
    arguments_object_needed: bool = false,
    arguments_disallowed: bool = false,
};

const Location = struct {
    offset: NewToken.ByteOffset,
};

const Tokenizer = struct {
    pub const Token = struct {
        location: Location,
        text: []const u8,
        type: TokenType,
    };
    pub const TokenType = enum {
        @"--",
        @"-",
        @"-=",
        @",",
        @";",
        @":",
        @"!",
        @"!=",
        @"!==",
        @"??",
        @"??=",
        @"?.",
        @"?",
        @".",
        @"...",
        @"(",
        @")",
        @"[",
        @"]",
        @"{",
        @"}",
        @"*",
        @"**",
        @"**=",
        @"*=",
        @"/",
        @"/=",
        @"&",
        @"&&",
        @"&&=",
        @"&=",
        @"#",
        @"%",
        @"%=",
        @"^",
        @"^=",
        @"+",
        @"++",
        @"+=",
        @"<",
        @"<<",
        @"<<=",
        @"<=",
        @"=",
        @"==",
        @"===",
        @"=>",
        @">",
        @">=",
        @">>",
        @">>=",
        @">>>",
        @">>>=",
        @"|",
        @"|=",
        @"||",
        @"||=",
        @"~",
        await,
        @"break",
        case,
        @"catch",
        class,
        @"const",
        @"continue",
        debugger,
        default,
        delete,
        do,
        @"else",
        @"enum",
        @"export",
        extends,
        false,
        finally,
        @"for",
        function,
        identifier,
        private_identifier,
        @"if",
        import,
        in,
        instanceof,
        new,
        null,
        numeric,
        regular_expression,
        @"return",
        string,
        super,
        @"switch",
        template,
        template_head,
        template_middle,
        template_tail,
        this,
        throw,
        true,
        @"try",
        typeof,
        @"var",
        void,
        @"while",
        with,
        yield,
        line_comment,
        multiline_comment,
        html_open_comment,
        html_close_comment,
        hashbang_comment,

        pub fn fromTag(tag: NewToken.Tag) TokenType {
            return switch (tag) {
                .invalid => unreachable,
                .identifier => .identifier,
                .private_identifier => .private_identifier,
                .keyword_await => .await,
                .keyword_break => .@"break",
                .keyword_case => .case,
                .keyword_catch => .@"catch",
                .keyword_class => .class,
                .keyword_const => .@"const",
                .keyword_continue => .@"continue",
                .keyword_debugger => .debugger,
                .keyword_default => .default,
                .keyword_delete => .delete,
                .keyword_do => .do,
                .keyword_else => .@"else",
                .keyword_enum => .@"enum",
                .keyword_export => .@"export",
                .keyword_extends => .extends,
                .keyword_false => .false,
                .keyword_finally => .finally,
                .keyword_for => .@"for",
                .keyword_function => .function,
                .keyword_if => .@"if",
                .keyword_import => .import,
                .keyword_in => .in,
                .keyword_instanceof => .instanceof,
                .keyword_new => .new,
                .keyword_null => .null,
                .keyword_return => .@"return",
                .keyword_super => .super,
                .keyword_switch => .@"switch",
                .keyword_this => .this,
                .keyword_throw => .throw,
                .keyword_true => .true,
                .keyword_try => .@"try",
                .keyword_typeof => .typeof,
                .keyword_var => .@"var",
                .keyword_void => .void,
                .keyword_while => .@"while",
                .keyword_with => .with,
                .keyword_yield => .yield,
                .question_mark_period => .@"?.",
                .left_curly_bracket => .@"{",
                .right_curly_bracket => .@"}",
                .left_parenthesis => .@"(",
                .right_parenthesis => .@")",
                .left_square_bracket => .@"[",
                .right_square_bracket => .@"]",
                .period => .@".",
                .ellipsis => .@"...",
                .semicolon => .@";",
                .comma => .@",",
                .less_than => .@"<",
                .greater_than => .@">",
                .less_than_equals => .@"<=",
                .greater_than_equals => .@">=",
                .double_equals => .@"==",
                .exclamation_mark_equals => .@"!=",
                .triple_equals => .@"===",
                .exclamation_mark_double_equals => .@"!==",
                .plus => .@"+",
                .minus => .@"-",
                .asterisk => .@"*",
                .percent => .@"%",
                .double_asterisk => .@"**",
                .double_plus => .@"++",
                .double_minus => .@"--",
                .double_less_than => .@"<<",
                .double_greater_than => .@">>",
                .triple_greater_than => .@">>>",
                .ampersand => .@"&",
                .pipe => .@"|",
                .caret => .@"^",
                .exclamation_mark => .@"!",
                .tilde => .@"~",
                .double_ampersand => .@"&&",
                .double_pipe => .@"||",
                .double_question_mark => .@"??",
                .question_mark => .@"?",
                .colon => .@":",
                .equals => .@"=",
                .plus_equals => .@"+=",
                .minus_equals => .@"-=",
                .asterisk_equals => .@"*=",
                .percent_equals => .@"%=",
                .double_asterisk_equals => .@"**=",
                .double_less_than_equals => .@"<<=",
                .double_greater_than_equals => .@">>=",
                .triple_greater_than_equals => .@">>>=",
                .ampersand_equals => .@"&=",
                .pipe_equals => .@"|=",
                .caret_equals => .@"^=",
                .double_ampersand_equals => .@"&&=",
                .double_pipe_equals => .@"||=",
                .double_question_mark_equals => .@"??=",
                .equals_greater_than => .@"=>",
                .slash => .@"/",
                .slash_equals => .@"/=",
                .number_literal, .bigint_literal => .numeric,
                .string_literal => .string,
                .regexp_literal => .regular_expression,
                .template_literal => .template,
                .template_literal_head => .template_head,
                .template_literal_middle => .template_middle,
                .template_literal_tail => .template_tail,
                .line_comment => .line_comment,
                .multiline_comment => .multiline_comment,
                .html_open_comment => .html_open_comment,
                .html_close_comment => .html_close_comment,
                .hashbang_comment => .hashbang_comment,
            };
        }
    };
    pub const State = struct {
        location: Location,
        token_index: u32,
    };
    pub const NextError = error{ UnexpectedCharacter, OutOfMemory };

    const TokenList = std.MultiArrayList(NewToken);

    source: []const u8,
    offset: u32,
    current_location: Location,
    tokens_slice: TokenList.Slice,
    token_index: u32,

    pub fn init(
        gpa: std.mem.Allocator,
        source: [:0]const u8,
        diagnostics: *Diagnostics,
        is_module: bool,
    ) std.mem.Allocator.Error!Tokenizer {
        var tokens: TokenList = .empty;
        errdefer tokens.deinit(gpa);
        var tokenizer: NewTokenizer = .init(gpa, source);
        defer tokenizer.deinit();
        while (try tokenizer.next()) |token| {
            switch (token.tag) {
                .line_comment, .multiline_comment, .hashbang_comment => {},
                .html_open_comment, .html_close_comment => if (is_module or !build_options.enable_annex_b) {
                    if (is_module) {
                        try diagnostics.emit(@backingInt(token.start), "HTML-like comments are not allowed in module code", .{});
                    } else {
                        try diagnostics.emit(@backingInt(token.start), "HTML-like comments are not enabled", .{});
                    }
                },
                else => try tokens.append(gpa, token),
            }
        }
        var tokens_slice = tokens.toOwnedSlice();
        errdefer tokens_slice.deinit(gpa);
        return .{
            .source = source,
            .offset = 0,
            .current_location = .{ .offset = @fromBackingInt(0) },
            .tokens_slice = tokens_slice,
            .token_index = 0,
        };
    }

    pub fn deinit(t: *Tokenizer, gpa: std.mem.Allocator) void {
        t.tokens_slice.deinit(gpa);
    }

    pub fn saveState(t: *Tokenizer) Tokenizer.State {
        return .{
            .location = t.current_location,
            .token_index = t.token_index,
        };
    }

    pub fn restoreState(t: *Tokenizer, state: Tokenizer.State) void {
        t.offset = @backingInt(state.location.offset);
        t.current_location = state.location;
        t.token_index = state.token_index;
    }

    pub fn next(t: *Tokenizer) NextError!?Token {
        if (t.token_index < t.tokens_slice.len) {
            const token = t.tokens_slice.get(t.token_index);
            t.token_index += 1;
            t.current_location = .{ .offset = token.start };
            if (token.tag == .invalid) {
                t.offset = @backingInt(token.start);
                return error.UnexpectedCharacter;
            }
            t.offset = @backingInt(token.end);
            t.current_location = .{ .offset = token.end };
            return .{
                .type = .fromTag(token.tag),
                .text = token.text(t.source),
                .location = .{ .offset = token.start },
            };
        }
        return null;
    }
};

const RuleSet = ptk.RuleSet(Tokenizer.TokenType);
const ParserCore = ptk.ParserCore(Tokenizer, .{
    .line_comment,
    .multiline_comment,
    .html_open_comment,
    .html_close_comment,
    .hashbang_comment,
});

pub const AcceptError = std.mem.Allocator.Error || ParserCore.AcceptError;

pub const Error = error{
    ParseError,
    OutOfMemory,
};

pub const Options = struct {
    diagnostics: ?*Diagnostics = null,
    state: State = .{},
};

const AcceptContext = struct {
    precedence: Precedence = 0,
    associativity: ?Associativity = null,
    forbidden: []const Tokenizer.TokenType = &.{},
    update_strict_mode: bool = false,
};

const Precedence = u5;
const Associativity = enum {
    left_to_right,
    right_to_left,
};

const PrecedenceAndAssociativityAltFlag = enum {
    prefix_increment,
    prefix_decrement,
    unary_plus,
    unary_minus,
};

fn getPrecedenceAndAssociativity(
    token_type: Tokenizer.TokenType,
) struct { Precedence, ?Associativity } {
    // https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Operators/Operator_Precedence#table
    return switch (token_type) {
        .@"(" => .{ 18, null },
        .@".",
        .@"?.",
        => .{ 17, .left_to_right },
        .@"[" => .{ 17, null },
        .new => .{ 16, null },
        .@"++",
        .@"--",
        => .{ 15, null },
        .@"!",
        .@"~",
        .typeof,
        .void,
        .delete,
        .await,
        => .{ 14, null },
        .@"**" => .{ 13, .right_to_left },
        .@"*",
        .@"/",
        .@"%",
        => .{ 12, .left_to_right },
        .@"+",
        .@"-",
        => .{ 11, .left_to_right },
        .@"<<",
        .@">>",
        .@">>>",
        => .{ 10, .left_to_right },
        .@"<",
        .@"<=",
        .@">",
        .@">=",
        .in,
        .instanceof,
        => .{ 9, .left_to_right },
        .@"==",
        .@"!=",
        .@"===",
        .@"!==",
        => .{ 8, .left_to_right },
        .@"&" => .{ 7, .left_to_right },
        .@"^" => .{ 6, .left_to_right },
        .@"|" => .{ 5, .left_to_right },
        .@"&&" => .{ 4, .left_to_right },
        .@"||",
        .@"??",
        => .{ 3, .left_to_right },
        .@"=",
        .@"+=",
        .@"-=",
        .@"**=",
        .@"*=",
        .@"/=",
        .@"%=",
        .@"<<=",
        .@">>=",
        .@">>>=",
        .@"&=",
        .@"^=",
        .@"|=",
        .@"&&=",
        .@"||=",
        .@"??=",
        => .{ 2, .right_to_left },
        .@"?" => .{ 2, .right_to_left },
        .@"=>" => .{ 2, .right_to_left },
        .yield,
        .@"...",
        => .{ 2, null },
        .@"," => .{ 1, .left_to_right },
        else => .{ 0, null },
    };
}

fn getPrecedenceAndAssociativityAlt(
    flag: PrecedenceAndAssociativityAltFlag,
) struct { Precedence, ?Associativity } {
    return switch (flag) {
        .prefix_increment,
        .prefix_decrement,
        .unary_plus,
        .unary_minus,
        => .{ 14, null },
    };
}

fn getPrecedence(token_type: Tokenizer.TokenType) Precedence {
    return getPrecedenceAndAssociativity(token_type)[0];
}

fn getPrecedenceAlt(flag: PrecedenceAndAssociativityAltFlag) Precedence {
    return getPrecedenceAndAssociativityAlt(flag)[0];
}

fn getAssociativity(token_type: Tokenizer.TokenType) ?Associativity {
    return getPrecedenceAndAssociativity(token_type)[1];
}

fn getAssociativityAlt(flag: PrecedenceAndAssociativityAltFlag) ?Associativity {
    return getPrecedenceAndAssociativityAlt(flag)[1];
}

pub fn parse(
    comptime T: type,
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    options: Options,
) Error!T {
    if (T != ast.Script and T != ast.Module)
        @compileError("Parser.parse() is only implemented for ast.Script and ast.Module");

    return parseNode(
        T,
        struct {
            fn accept(parser: *Parser) AcceptError!T {
                if (T == ast.Script)
                    return parser.acceptScript()
                else
                    return parser.acceptModule();
            }
        }.accept,
        allocator,
        source,
        options,
    );
}

pub fn parseNode(
    comptime T: type,
    comptime acceptFn: fn (*Parser) anyerror!T,
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    options: Options,
) Error!T {
    var new_diagnostics: Diagnostics = undefined;
    defer if (options.diagnostics == null) new_diagnostics.deinit();
    const diagnostics = options.diagnostics orelse blk: {
        new_diagnostics = .init(allocator, .{ .source = source, .file_name = null });
        break :blk &new_diagnostics;
    };
    var tokenizer = try Tokenizer.init(
        allocator,
        source,
        diagnostics,
        T == ast.Module,
    );
    defer tokenizer.deinit(allocator);
    const core = ParserCore.init(&tokenizer);
    var parser: Parser = .{
        .allocator = allocator,
        .core = core,
        .diagnostics = diagnostics,
        .identifier_stack = .empty,
        .state = options.state,
    };
    defer parser.identifier_stack.deinit(allocator);
    const ast_node: ?T = acceptFn(&parser) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => null,
    };
    if (parser.diagnostics.hasErrors()) {
        return error.ParseError;
    } else if (parser.core.peek()) |maybe_next_token| {
        if (maybe_next_token) |next_token| {
            try parser.emitError("Unexpected token '{t}'", .{next_token.type});
            return error.ParseError;
        }
    } else |_| {
        // If peek() returned UnexpectedCharacter, the tokenizer state is restored to the last
        // 'good' position, which means we also have to re-consume any whitespace and other ignored
        // tokens preceding the invalid character.
        while (parser.core.tokenizer.next() catch null) |_| {}
        const offset = parser.core.tokenizer.offset;
        std.debug.assert(offset < source.len);
        try parser.emitError("Invalid character '{s}'", .{source[offset .. offset + 1]});
        return error.ParseError;
    }
    return ast_node.?;
}

fn peekToken(self: *Parser) ParserCore.AcceptError!Tokenizer.Token {
    return try self.core.peek() orelse return error.EndOfStream;
}

/// Report a syntax error on the current token.
fn emitError(self: *Parser, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
    try self.emitErrorAt(self.core.tokenizer.current_location, fmt, args);
}

/// Report a syntax error at a specific source location.
fn emitErrorAt(
    self: *Parser,
    location: Location,
    comptime fmt: []const u8,
    args: anytype,
) std.mem.Allocator.Error!void {
    @branchHint(.cold);
    try self.diagnostics.emit(@backingInt(location.offset), fmt, args);
}

fn identifierNameValue(self: *Parser, text: []const u8) AcceptError![]const u8 {
    if (std.mem.findScalar(u8, text, '\\') == null) {
        return self.allocator.dupe(u8, text);
    }
    var aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer aw.deinit();
    const literal: NewTokenizer.IdentifierName = .{ .text = text };
    const valid = literal.value(&aw.writer) catch return error.OutOfMemory;
    if (!valid) return error.UnexpectedToken;
    return aw.toOwnedSlice();
}

/// 12.7.2 Keywords and Reserved Words
/// https://tc39.es/ecma262/#sec-keywords-and-reserved-words
const reserved_words = [_][]const u8{
    "await",   "break",  "case",     "catch",  "class",  "const",  "continue",   "debugger",
    "default", "delete", "do",       "else",   "enum",   "export", "extends",    "false",
    "finally", "for",    "function", "if",     "import", "in",     "instanceof", "new",
    "null",    "return", "super",    "switch", "this",   "throw",  "true",       "try",
    "typeof",  "var",    "void",     "while",  "with",   "yield",
};

/// 12.7.2 Keywords and Reserved Words
/// https://tc39.es/ecma262/#sec-keywords-and-reserved-words
const strict_mode_reserved_words = [_][]const u8{
    "let", "static", "implements", "interface", "package", "private", "protected", "public",
};

fn unescapeIdentifier(self: *Parser, token: Tokenizer.Token) AcceptError![]const u8 {
    const string_value = try self.identifierNameValue(token.text);
    if (token.type == .identifier) {
        // It is a Syntax Error if the goal symbol of the syntactic grammar is Module and the
        // StringValue of IdentifierName is "await".
        if (self.state.in_module and std.mem.eql(u8, string_value, "await")) {
            try self.emitErrorAt(
                token.location,
                "Identifier named 'await' not allowed in modules",
                .{},
            );
        }
        // It is a Syntax Error if the StringValue of IdentifierName is the StringValue of any
        // ReservedWord except for yield or await.
        for (reserved_words) |reserved_word| {
            if (std.mem.eql(u8, string_value, reserved_word)) {
                if (std.mem.eql(u8, string_value, "yield") or
                    std.mem.eql(u8, string_value, "await")) continue;
                try self.emitErrorAt(
                    token.location,
                    "Keyword must not contain escaped characters",
                    .{},
                );
                break;
            }
        }
    } else {
        std.debug.assert(token.type == .yield or token.type == .await);
    }
    return string_value;
}

const IdentifierStackRange = struct {
    parser: *Parser,
    start: usize,
    end: ?usize,

    pub fn open(parser: *Parser) IdentifierStackRange {
        return .{
            .parser = parser,
            .start = parser.identifier_stack.items.len,
            .end = null,
        };
    }

    pub fn close(self: *IdentifierStackRange) void {
        self.end = self.parser.identifier_stack.items.len;
    }

    /// Must call close() before calling this.
    pub fn slice(self: IdentifierStackRange) []ast.Identifier {
        return self.parser.identifier_stack.items[self.start..self.end.?];
    }

    pub fn deinit(self: IdentifierStackRange) void {
        self.parser.identifier_stack.shrinkRetainingCapacity(self.start);
    }
};

fn ensureSimpleParameterList(
    self: *Parser,
    formal_parameters: ast.FormalParameters,
    location: Location,
) std.mem.Allocator.Error!void {
    if (!formal_parameters.isSimpleParameterList()) {
        try self.emitErrorAt(
            location,
            "Function with 'use strict' directive must have a simple parameter list",
            .{},
        );
    }
}

fn ensureUniqueParameterNames(
    self: *Parser,
    kind: enum { strict, arrow, method, non_simple },
    formal_parameters: ast.FormalParameters,
    location: Location,
) std.mem.Allocator.Error!void {
    var bound_names = IdentifierStackRange.open(self);
    defer bound_names.deinit();
    try formal_parameters.collectBoundNames(self.allocator, &self.identifier_stack);
    bound_names.close();
    var seen_bound_names: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_bound_names.deinit(self.allocator);
    try seen_bound_names.ensureTotalCapacity(self.allocator, @intCast(bound_names.slice().len));
    for (bound_names.slice()) |bound_name| {
        if (seen_bound_names.fetchPutAssumeCapacity(bound_name, {})) |_| {
            switch (kind) {
                .strict => try self.emitErrorAt(
                    location,
                    "Function must not have duplicate parameter names in strict mode",
                    .{},
                ),
                .arrow => try self.emitErrorAt(
                    location,
                    "Arrow function must not have duplicate parameter names",
                    .{},
                ),
                .method => try self.emitErrorAt(
                    location,
                    "Method must not have duplicate parameter names",
                    .{},
                ),
                .non_simple => try self.emitErrorAt(
                    location,
                    "Function with non-simple parameter list must not have duplicate parameter names",
                    .{},
                ),
            }
        }
    }
}

fn ensureAllowedParameterNames(
    self: *Parser,
    formal_parameters: ast.FormalParameters,
    location: Location,
) AcceptError!void {
    var bound_names = IdentifierStackRange.open(self);
    defer bound_names.deinit();
    try formal_parameters.collectBoundNames(self.allocator, &self.identifier_stack);
    bound_names.close();
    for (bound_names.slice()) |bound_name| {
        try self.ensureAllowedIdentifier(.function_parameter, bound_name, location);
    }
}

fn ensureAllowedIdentifier(
    self: *Parser,
    kind: enum { binding_identifier, identifier_reference, function_parameter },
    value: []const u8,
    location: Location,
) std.mem.Allocator.Error!void {
    if (containsSlice(&strict_mode_reserved_words, value) or
        // https://tc39.es/ecma262/#sec-keywords-and-reserved-words:~:text=code%2E-,Note%203
        std.mem.eql(u8, value, "arguments") or
        std.mem.eql(u8, value, "eval"))
    {
        switch (kind) {
            .binding_identifier => try self.emitErrorAt(
                location,
                "Binding identifier named '{s}' is not allowed in strict mode",
                .{value},
            ),
            .identifier_reference => try self.emitErrorAt(
                location,
                "Identifier reference named '{s}' is not allowed in strict mode",
                .{value},
            ),
            .function_parameter => try self.emitErrorAt(
                location,
                "Function parameter named '{s}' is not allowed in strict mode",
                .{value},
            ),
        }
    }
}

fn ensureUniqueLexicallyDeclaredNames(
    self: *Parser,
    lexically_declared_names: []const ast.Identifier,
    var_declared_names: []const ast.Identifier,
    location: Location,
) std.mem.Allocator.Error!void {
    try self.ensureUniqueBoundNames(.lexical_declaration, lexically_declared_names, location);

    try self.ensureBoundNamesNotVarDeclared(
        .lexical_declaration,
        lexically_declared_names,
        var_declared_names,
        location,
    );
}

fn ensureUniqueBoundNames(
    self: *Parser,
    kind: enum { lexical_declaration, for_declaration },
    bound_names: []const ast.Identifier,
    location: Location,
) std.mem.Allocator.Error!void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(self.allocator);

    for (bound_names) |name| {
        if (seen.contains(name)) {
            switch (kind) {
                .lexical_declaration => try self.emitErrorAt(
                    location,
                    "Lexical declaration has duplicate binding '{s}'",
                    .{name},
                ),
                .for_declaration => try self.emitErrorAt(
                    location,
                    "For declaration has duplicate binding '{s}'",
                    .{name},
                ),
            }
        }
        try seen.put(self.allocator, name, {});
    }
}

fn ensureBoundNamesNotVarDeclared(
    self: *Parser,
    kind: enum { lexical_declaration, for_declaration },
    bound_names: []const ast.Identifier,
    var_declared_names: []const ast.Identifier,
    location: Location,
) std.mem.Allocator.Error!void {
    var var_names_set: std.StringHashMapUnmanaged(void) = .empty;
    try var_names_set.ensureUnusedCapacity(self.allocator, @intCast(var_declared_names.len));
    defer var_names_set.deinit(self.allocator);
    for (var_declared_names) |name| var_names_set.putAssumeCapacity(name, {});

    for (bound_names) |name| {
        if (var_names_set.contains(name)) {
            switch (kind) {
                .lexical_declaration => try self.emitErrorAt(
                    location,
                    "Lexical declaration '{s}' is also var-declared",
                    .{name},
                ),
                .for_declaration => try self.emitErrorAt(
                    location,
                    "For declaration '{s}' is also var-declared",
                    .{name},
                ),
            }
        }
    }
}

fn ensureUniqueCatchParameterNames(
    self: *Parser,
    bound_names: []const ast.Identifier,
    lexically_declared_names: []const ast.Identifier,
    var_declared_names: []const ast.Identifier,
    location: Location,
    allows_var_redeclaration: bool,
) std.mem.Allocator.Error!void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(self.allocator);

    var lexical_names_set: std.StringHashMapUnmanaged(void) = .empty;
    try lexical_names_set.ensureUnusedCapacity(self.allocator, @intCast(lexically_declared_names.len));
    defer lexical_names_set.deinit(self.allocator);
    for (lexically_declared_names) |name| lexical_names_set.putAssumeCapacity(name, {});

    var var_names_set: std.StringHashMapUnmanaged(void) = .empty;
    try var_names_set.ensureUnusedCapacity(self.allocator, @intCast(var_declared_names.len));
    defer var_names_set.deinit(self.allocator);
    for (var_declared_names) |name| var_names_set.putAssumeCapacity(name, {});

    for (bound_names) |name| {
        if (seen.contains(name)) {
            try self.emitErrorAt(location, "Catch parameter has duplicate binding '{s}'", .{name});
        }
        try seen.put(self.allocator, name, {});

        if (lexical_names_set.contains(name)) {
            try self.emitErrorAt(
                location,
                "Catch parameter '{s}' is also lexically declared",
                .{name},
            );
        }

        if (!allows_var_redeclaration and var_names_set.contains(name)) {
            try self.emitErrorAt(
                location,
                "Catch parameter '{s}' is also var-declared",
                .{name},
            );
        }
    }
}

fn ensureUniquePrivateClassElementNames(
    self: *Parser,
    class_body: ast.ClassBody,
    location: Location,
) std.mem.Allocator.Error!void {
    const Kind = enum { getter, setter, other };
    const Seen = std.EnumSet(Kind);
    var seen_private_names: std.StringHashMapUnmanaged(Seen) = .empty;
    defer seen_private_names.deinit(self.allocator);

    for (class_body.class_element_list.items) |class_element| {
        const private_identifier: ast.PrivateIdentifier = switch (class_element) {
            .method_definition => |method_definition| switch (method_definition.class_element_name) {
                .private_identifier => |name| name,
                .property_name => continue,
            },
            .static_method_definition => |method_definition| switch (method_definition.class_element_name) {
                .private_identifier => |name| name,
                .property_name => continue,
            },
            .field_definition => |field_definition| switch (field_definition.class_element_name) {
                .private_identifier => |name| name,
                .property_name => continue,
            },
            .static_field_definition => |field_definition| switch (field_definition.class_element_name) {
                .private_identifier => |name| name,
                .property_name => continue,
            },
            .class_static_block, .empty_statement => continue,
        };

        const kind: Kind = switch (class_element) {
            .method_definition => |method_definition| switch (method_definition.method) {
                .get => .getter,
                .set => .setter,
                else => .other,
            },
            .static_method_definition => |method_definition| switch (method_definition.method) {
                .get => .getter,
                .set => .setter,
                else => .other,
            },
            .field_definition, .static_field_definition => .other,
            .class_static_block, .empty_statement => unreachable,
        };

        const result = try seen_private_names.getOrPut(self.allocator, private_identifier);
        if (!result.found_existing) {
            result.value_ptr.* = .empty;
        }
        const seen = result.value_ptr;

        const duplicate = switch (kind) {
            .getter => seen.contains(.getter) or seen.contains(.other),
            .setter => seen.contains(.setter) or seen.contains(.other),
            .other => seen.contains(.other) or seen.contains(.getter) or seen.contains(.setter),
        };
        seen.insert(kind);
        if (duplicate) {
            try self.emitErrorAt(
                location,
                "Class has duplicate private element '#{s}'",
                .{private_identifier},
            );
        }
    }
}

fn ensureUniqueConstructorMethod(
    self: *Parser,
    class_body: ast.ClassBody,
    location: Location,
) std.mem.Allocator.Error!void {
    var seen = false;
    const duplicate = for (class_body.class_element_list.items) |class_element| {
        if (try class_element.classElementKind(self.allocator) == .constructor_method) {
            if (seen) break true;
            seen = true;
        }
    } else false;
    if (duplicate) {
        try self.emitErrorAt(
            location,
            "Class must not have more than one constructor",
            .{},
        );
    }
}

/// 5.1.5.8 [no LineTerminator here]
/// https://tc39.es/ecma262/#sec-no-lineterminator-here
fn followedByLineTerminator(self: *Parser) bool {
    // Same as peek() but without immediately restoring the state; we need to look at what's
    // between the current and next token.
    const state = self.core.saveState();
    defer self.core.restoreState(state);

    const next_token = (self.core.nextToken() catch return false) orelse return false;

    const start_offset = @backingInt(state.location.offset);
    const end_offset = self.core.tokenizer.offset - next_token.text.len;
    const whitespace_and_comments = self.core.tokenizer.source[start_offset..end_offset];

    return findLineTerminator(whitespace_and_comments) != null;
}

/// 12.10 Automatic Semicolon Insertion
/// https://tc39.es/ecma262/#sec-automatic-semicolon-insertion
pub fn acceptOrInsertSemicolon(self: *Parser) AcceptError!void {
    // Next token is ';', consume semicolon
    if (self.core.accept(RuleSet.is(.@";"))) |_|
        return
    else |_| {}

    // Same as peek() but without immediately restoring the state; we need to look at what's
    // between the current and next token.
    const state = self.core.saveState();
    defer self.core.restoreState(state);
    const maybe_next_token = try self.core.nextToken();

    // Next token is EOF, insert semicolon
    if (maybe_next_token == null) return;

    const next_token = maybe_next_token.?;

    // Next token is '}', insert semicolon
    if (next_token.type == .@"}") return;

    const start_offset = @backingInt(state.location.offset);
    const end_offset = self.core.tokenizer.offset - next_token.text.len;
    const whitespace_and_comments = self.core.tokenizer.source[start_offset..end_offset];

    // Next token is separated by a newline, insert semicolon
    if (findLineTerminator(whitespace_and_comments)) |_| return;

    return error.UnexpectedToken;
}

pub fn acceptKeyword(self: *Parser, value: []const u8) AcceptError!Tokenizer.Token {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const token = try self.core.accept(RuleSet.is(.identifier));
    if (!std.mem.eql(u8, token.text, value)) return error.UnexpectedToken;
    return token;
}

pub fn acceptIdentifierName(self: *Parser) AcceptError!ast.Identifier {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const reserved_word_token_types = comptime blk: {
        var reserved_word_token_types: [reserved_words.len]Tokenizer.TokenType = undefined;
        for (reserved_words, 0..) |reserved_word, i| {
            reserved_word_token_types[i] = @field(Tokenizer.TokenType, reserved_word);
        }
        break :blk reserved_word_token_types;
    };
    const token = try self.core.accept(RuleSet.oneOf(.{.identifier} ++ reserved_word_token_types));
    return self.identifierNameValue(token.text);
}

pub fn acceptIdentifierReference(self: *Parser) AcceptError!ast.IdentifierReference {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const token = try self.core.accept(RuleSet.oneOf(.{ .identifier, .yield, .await }));
    if (self.core.peek() catch null) |next_token| {
        if (next_token.type == .@"=>") return error.UnexpectedToken;
        if (std.mem.eql(u8, token.text, "async")) {
            if (!self.followedByLineTerminator()) {
                // AsyncFunction{Expression,Declaration}
                if (next_token.type == .function) return error.UnexpectedToken;
                // AsyncArrowFunction
                if (next_token.type == .@"(" or next_token.type == .identifier) return error.UnexpectedToken;
            }
        }
    }
    const string_value = try self.unescapeIdentifier(token);

    switch (token.type) {
        .identifier => {
            // It is a Syntax Error if IsStrict(this phrase) is true and the StringValue of
            // IdentifierName is one of "implements", "interface", "let", "package", "private",
            // "protected", "public", "static", or "yield".
            if (self.state.in_strict_mode and std.mem.eql(u8, string_value, "yield")) {
                try self.emitErrorAt(
                    token.location,
                    "Identifier reference named 'yield' is not allowed in strict mode",
                    .{},
                );
            }
            // It is a Syntax Error if this production has a [Yield] parameter and the StringValue
            // of Identifier is "yield".
            if (self.state.in_generator_function and std.mem.eql(u8, string_value, "yield")) {
                try self.emitErrorAt(
                    token.location,
                    "Identifier reference named 'yield' not allowed in generator functions",
                    .{},
                );
            }

            // It is a Syntax Error if the goal symbol of the syntactic grammar is Module and the
            // StringValue of IdentifierName is "await".
            if (self.state.in_module and std.mem.eql(u8, string_value, "await")) {
                try self.emitErrorAt(
                    token.location,
                    "Identifier reference named 'await' not allowed in modules",
                    .{},
                );
            }
            // It is a Syntax Error if this production has an [Await] parameter and the StringValue
            // of Identifier is "await".
            if ((self.state.in_async_function or self.state.in_class_static_block) and
                std.mem.eql(u8, string_value, "await"))
            {
                try self.emitErrorAt(
                    token.location,
                    "Identifier reference named 'await' not allowed in async functions or class static blocks",
                    .{},
                );
            }
            // - It is a Syntax Error if Initializer is present and ContainsArguments of
            //   Initializer is true.
            // - It is a Syntax Error if ContainsArguments of ClassStaticBlockStatementList is
            //   true.
            if (self.state.arguments_disallowed and std.mem.eql(u8, string_value, "arguments")) {
                try self.emitErrorAt(
                    token.location,
                    "Identifier reference named 'arguments' not allowed in class field initializers or class static blocks",
                    .{},
                );
            }
        },
        .yield => {
            // It is a Syntax Error if IsStrict(this production) is true.
            if (self.state.in_strict_mode) {
                try self.emitErrorAt(
                    token.location,
                    "Identifier reference named 'yield' is not allowed in strict mode",
                    .{},
                );
            }
            // It is a Syntax Error if this production has a [Yield] parameter.
            if (self.state.in_generator_function) {
                try self.emitErrorAt(
                    token.location,
                    "Identifier reference named 'yield' not allowed in generator functions",
                    .{},
                );
            }
        },
        .await => {
            // It is a Syntax Error if the goal symbol of the syntactic grammar is Module.
            if (self.state.in_module) {
                try self.emitErrorAt(
                    token.location,
                    "Identifier reference named 'await' not allowed in modules",
                    .{},
                );
            }
            // It is a Syntax Error if this production has an [Await] parameter.
            if (self.state.in_async_function or self.state.in_class_static_block) {
                try self.emitErrorAt(
                    token.location,
                    "Identifier reference named 'await' not allowed in async functions or class static blocks",
                    .{},
                );
            }
        },
        else => unreachable,
    }

    return string_value;
}

pub fn acceptBindingIdentifier(self: *Parser) AcceptError!ast.Identifier {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const token = try self.core.accept(RuleSet.oneOf(.{ .identifier, .yield, .await }));
    const string_value = try self.unescapeIdentifier(token);

    switch (token.type) {
        .identifier => {
            // It is a Syntax Error if IsStrict(this production) is true and the StringValue of
            // Identifier is either "arguments" or "eval".
            if (self.state.in_strict_mode) {
                try self.ensureAllowedIdentifier(.binding_identifier, string_value, token.location);
            }

            // It is a Syntax Error if IsStrict(this phrase) is true and the StringValue of
            // IdentifierName is one of "implements", "interface", "let", "package", "private",
            // "protected", "public", "static", or "yield".
            if (self.state.in_strict_mode and std.mem.eql(u8, string_value, "yield")) {
                try self.emitErrorAt(
                    token.location,
                    "Binding identifier named 'yield' is not allowed in strict mode",
                    .{},
                );
            }
            // It is a Syntax Error if this production has a [Yield] parameter and the StringValue
            // of Identifier is "yield".
            if (self.state.in_generator_function and std.mem.eql(u8, string_value, "yield")) {
                try self.emitErrorAt(
                    token.location,
                    "Binding identifier named 'yield' not allowed in generator functions",
                    .{},
                );
            }

            // It is a Syntax Error if the goal symbol of the syntactic grammar is Module and the
            // StringValue of IdentifierName is "await".
            if (self.state.in_module and std.mem.eql(u8, string_value, "await")) {
                try self.emitErrorAt(
                    token.location,
                    "Binding identifier named 'await' not allowed in modules",
                    .{},
                );
            }
            // It is a Syntax Error if this production has an [Await] parameter and the StringValue
            // of Identifier is "await".
            if ((self.state.in_async_function or self.state.in_class_static_block) and
                std.mem.eql(u8, string_value, "await"))
            {
                try self.emitErrorAt(
                    token.location,
                    "Binding identifier named 'await' not allowed in async functions or class static blocks",
                    .{},
                );
            }
        },
        .yield => {
            // It is a Syntax Error if IsStrict(this production) is true.
            if (self.state.in_strict_mode) {
                try self.emitErrorAt(
                    token.location,
                    "Binding identifier named 'yield' is not allowed in strict mode",
                    .{},
                );
            }
            // It is a Syntax Error if this production has a [Yield] parameter.
            if (self.state.in_generator_function) {
                try self.emitErrorAt(
                    token.location,
                    "Binding identifier named 'yield' not allowed in generator functions",
                    .{},
                );
            }
        },
        .await => {
            // It is a Syntax Error if the goal symbol of the syntactic grammar is Module.
            if (self.state.in_module) {
                try self.emitErrorAt(
                    token.location,
                    "Binding identifier named 'await' not allowed in modules",
                    .{},
                );
            }
            // It is a Syntax Error if this production has an [Await] parameter.
            if (self.state.in_async_function or self.state.in_class_static_block) {
                try self.emitErrorAt(
                    token.location,
                    "Binding identifier named 'await' not allowed in async functions or class static blocks",
                    .{},
                );
            }
        },
        else => unreachable,
    }

    return string_value;
}

pub fn acceptLabelIdentifier(self: *Parser, for_labelled_statement: bool) AcceptError!ast.Identifier {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const token = try self.core.accept(RuleSet.oneOf(.{ .identifier, .yield, .await }));

    // Avoid needless validation if this is not the beginning of a labelled statement, otherwise
    // we'd have to drop the errors after finding the colon is missing.
    if (for_labelled_statement and (try self.peekToken()).type != .@":") {
        return error.UnexpectedToken;
    }

    const string_value = try self.unescapeIdentifier(token);

    switch (token.type) {
        .identifier => {
            // It is a Syntax Error if IsStrict(this phrase) is true and the StringValue of
            // IdentifierName is one of "implements", "interface", "let", "package", "private",
            // "protected", "public", "static", or "yield".
            if (self.state.in_strict_mode and std.mem.eql(u8, string_value, "yield")) {
                try self.emitErrorAt(
                    token.location,
                    "Label named 'yield' is not allowed in strict mode",
                    .{},
                );
            }
            // It is a Syntax Error if this production has a [Yield] parameter and the StringValue
            // of Identifier is "yield".
            if (self.state.in_generator_function and std.mem.eql(u8, string_value, "yield")) {
                try self.emitErrorAt(
                    token.location,
                    "Label named 'yield' not allowed in generator functions",
                    .{},
                );
            }

            // It is a Syntax Error if this production has an [Await] parameter and the StringValue
            // of Identifier is "await".
            if ((self.state.in_async_function or self.state.in_class_static_block) and
                std.mem.eql(u8, string_value, "await"))
            {
                try self.emitErrorAt(
                    token.location,
                    "Label named 'await' not allowed in async functions or class static blocks",
                    .{},
                );
            }
        },
        .yield => {
            // It is a Syntax Error if IsStrict(this production) is true.
            if (self.state.in_strict_mode) {
                try self.emitErrorAt(
                    token.location,
                    "Label named 'yield' is not allowed in strict mode",
                    .{},
                );
            }
            // It is a Syntax Error if this production has a [Yield] parameter and the StringValue
            // of Identifier is "yield".
            if (self.state.in_generator_function) {
                try self.emitErrorAt(
                    token.location,
                    "Label named 'yield' not allowed in generator functions",
                    .{},
                );
            }
        },
        .await => {
            // It is a Syntax Error if the goal symbol of the syntactic grammar is Module.
            if (self.state.in_module) {
                try self.emitErrorAt(
                    token.location,
                    "Label named 'await' not allowed in modules",
                    .{},
                );
            }
            // It is a Syntax Error if this production has an [Await] parameter and the StringValue
            // of Identifier is "await".
            if (self.state.in_async_function or self.state.in_class_static_block) {
                try self.emitErrorAt(
                    token.location,
                    "Label named 'await' not allowed in async functions or class static blocks",
                    .{},
                );
            }
        },
        else => unreachable,
    }

    return string_value;
}

pub fn acceptPrivateIdentifier(self: *Parser) AcceptError!ast.PrivateIdentifier {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const token = try self.core.accept(RuleSet.is(.private_identifier));

    if (!self.state.in_class_body) {
        try self.emitErrorAt(
            token.location,
            "Private identifier is only allowed in class body",
            .{},
        );
        return error.UnexpectedToken;
    }

    // Strip the leading '#'
    return self.identifierNameValue(token.text[1..]);
}

pub fn acceptPrimaryExpression(self: *Parser) AcceptError!ast.PrimaryExpression {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const error_count = self.diagnostics.errors.items.len;

    const next_token = try self.peekToken();
    return switch (next_token.type) {
        .this => blk: {
            _ = self.core.accept(RuleSet.is(.this)) catch unreachable;
            break :blk .this;
        },
        .identifier, .yield, .await => if (self.acceptIdentifierReference()) |identifier_reference|
            .{ .identifier_reference = identifier_reference }
        else |_| if (self.acceptArrowFunction()) |arrow_function|
            .{ .arrow_function = arrow_function }
        else |_| if (self.acceptAsyncFunctionExpression()) |async_function_expression|
            .{ .async_function_expression = async_function_expression }
        else |_| if (self.acceptAsyncGeneratorExpression()) |async_generator_expression|
            .{ .async_generator_expression = async_generator_expression }
        else |_| if (self.acceptAsyncArrowFunction()) |async_arrow_function|
            .{ .async_arrow_function = async_arrow_function }
        else |_|
            error.UnexpectedToken,
        .@"(" => if (self.acceptArrowFunction()) |arrow_function|
            .{ .arrow_function = arrow_function }
        else |_| blk: {
            // If parsing the arrow function failed we may have emitted an 'invalid binding
            // identifier' error, e.g. for `"use strict"; (eval)` - get rid of those
            while (self.diagnostics.errors.items.len > error_count) _ = self.diagnostics.errors.pop();
            break :blk error.UnexpectedToken;
        },
        .function => if (self.acceptFunctionExpression()) |function_expression|
            .{ .function_expression = function_expression }
        else |_| if (self.acceptGeneratorExpression()) |generator_expression|
            .{ .generator_expression = generator_expression }
        else |_|
            error.UnexpectedToken,
        .class => .{ .class_expression = try self.acceptClassExpression() },
        .@"[" => .{ .array_literal = try self.acceptArrayLiteral() },
        .@"{" => .{ .object_literal = try self.acceptObjectLiteral() },
        .numeric, .string, .null, .true, .false => .{ .literal = try self.acceptLiteral() },
        .regular_expression => .{ .regular_expression_literal = try self.acceptRegularExpressionLiteral() },
        .template, .template_head => .{ .template_literal = try self.acceptTemplateLiteral(false) },
        else => error.UnexpectedToken,
    };
}

pub fn acceptSecondaryExpression(
    self: *Parser,
    primary_expression: ast.Expression,
    ctx: AcceptContext,
) AcceptError!ast.Expression {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const next_token = try self.peekToken();
    return switch (next_token.type) {
        .@"[", .@"." => .{ .member_expression = try self.acceptMemberExpression(primary_expression) },
        .@"(" => .{ .call_expression = try self.acceptCallExpression(primary_expression) },
        .@"?." => .{ .optional_expression = try self.acceptOptionalExpression(primary_expression) },
        .@"++", .@"--" => .{ .update_expression = try self.acceptUpdateExpression(primary_expression) },
        .@"**", .@"*", .@"/", .@"%", .@"+", .@"-", .@"<<", .@">>", .@">>>", .@"&", .@"^", .@"|" => .{ .binary_expression = try self.acceptBinaryExpression(primary_expression, ctx) },
        .@">", .@"<", .@">=", .@"<=", .instanceof, .in => .{ .relational_expression = try self.acceptRelationalExpression(.{ .expression = primary_expression }, ctx) },
        .@"==", .@"!=", .@"===", .@"!==" => .{ .equality_expression = try self.acceptEqualityExpression(primary_expression, ctx) },
        .@"&&", .@"||", .@"??" => .{ .logical_expression = try self.acceptLogicalExpression(primary_expression, ctx) },
        .@"?" => .{ .conditional_expression = try self.acceptConditionalExpression(primary_expression, ctx) },
        .@"=", .@"*=", .@"/=", .@"%=", .@"+=", .@"-=", .@"<<=", .@">>=", .@">>>=", .@"&=", .@"^=", .@"|=", .@"**=", .@"&&=", .@"||=", .@"??=" => .{ .assignment_expression = try self.acceptAssignmentExpression(primary_expression, ctx) },
        .@"," => .{ .sequence_expression = try self.acceptSequenceExpression(primary_expression) },
        else => error.UnexpectedToken,
    };
}

pub fn acceptMemberExpression(
    self: *Parser,
    primary_expression: ast.Expression,
) AcceptError!ast.MemberExpression {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const token = try self.core.accept(RuleSet.oneOf(.{ .@"[", .@"." }));
    const property: ast.MemberExpression.Property = switch (token.type) {
        .@"[" => blk: {
            const property_expression = try self.allocator.create(ast.Expression);
            errdefer self.allocator.destroy(property_expression);
            property_expression.* = try self.acceptExpression(.{});
            _ = try self.core.accept(RuleSet.is(.@"]"));
            break :blk .{ .expression = property_expression };
        },
        .@"." => blk: {
            if (self.acceptIdentifierName()) |identifier|
                break :blk .{ .identifier = identifier }
            else |_| if (self.acceptPrivateIdentifier()) |private_identifier|
                break :blk .{ .private_identifier = private_identifier }
            else |_|
                return error.UnexpectedToken;
        },
        else => unreachable,
    };
    // Defer heap allocation of expression until we know this is a MemberExpression
    const expression = try self.allocator.create(ast.Expression);
    expression.* = primary_expression;
    return .{ .expression = expression, .property = property };
}

pub fn acceptSuperProperty(self: *Parser) AcceptError!ast.SuperProperty {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const super_token = try self.core.accept(RuleSet.is(.super));
    const token = try self.core.accept(RuleSet.oneOf(.{ .@"[", .@"." }));

    if (!(self.state.in_class_body or self.state.in_method_definition)) {
        try self.emitErrorAt(
            super_token.location,
            "'super' property is only allowed in classes and method definitions",
            .{},
        );
        return error.UnexpectedToken;
    }

    return switch (token.type) {
        .@"[" => blk: {
            const expression = try self.allocator.create(ast.Expression);
            errdefer self.allocator.destroy(expression);
            expression.* = try self.acceptExpression(.{});
            _ = try self.core.accept(RuleSet.is(.@"]"));
            break :blk .{ .expression = expression };
        },
        .@"." => .{ .identifier = try self.acceptIdentifierName() },
        else => unreachable,
    };
}

pub fn acceptMetaProperty(self: *Parser) AcceptError!ast.MetaProperty {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    if (self.acceptNewTarget())
        return .new_target
    else |_| if (self.acceptImportMeta())
        return .import_meta
    else |_|
        return error.UnexpectedToken;
}

pub fn acceptNewTarget(self: *Parser) AcceptError!void {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const token = try self.core.accept(RuleSet.is(.new));
    _ = try self.core.accept(RuleSet.is(.@"."));
    _ = try self.acceptKeyword("target");

    if (!self.state.new_target_allowed) {
        try self.emitErrorAt(token.location, "'new.target' is only allowed in functions", .{});
        return error.UnexpectedToken;
    }
}

pub fn acceptImportMeta(self: *Parser) AcceptError!void {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const token = try self.core.accept(RuleSet.is(.import));
    _ = try self.core.accept(RuleSet.is(.@"."));
    _ = try self.acceptKeyword("meta");

    if (!self.state.in_module) {
        try self.emitErrorAt(token.location, "'import.meta' is only allowed in modules", .{});
        return error.UnexpectedToken;
    }
}

pub fn acceptNewExpression(self: *Parser) AcceptError!ast.NewExpression {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const token = try self.core.accept(RuleSet.is(.new));
    const expression = blk: {
        const ctx: AcceptContext = .{
            .precedence = getPrecedence(.new),
            .forbidden = &.{ .@"(", .@"?." },
        };
        const expression = try self.allocator.create(ast.Expression);
        errdefer self.allocator.destroy(expression);
        expression.* = try self.acceptExpression(ctx);
        break :blk expression;
    };
    if (expression.* == .import_call) {
        try self.emitErrorAt(token.location, "'new' expression cannot be used with 'import()'", .{});
        return error.UnexpectedToken;
    }
    if (expression.* == .super_call) {
        try self.emitErrorAt(token.location, "'new' expression cannot be used with 'super()'", .{});
        return error.UnexpectedToken;
    }
    const arguments = self.acceptArguments() catch &[_]ast.Argument{};
    return .{ .expression = expression, .arguments = arguments };
}

pub fn acceptCallExpression(
    self: *Parser,
    primary_expression: ast.Expression,
) AcceptError!ast.CallExpression {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const arguments = try self.acceptArguments();
    // Defer heap allocation of expression until we know this is a CallExpression
    const expression = try self.allocator.create(ast.Expression);
    expression.* = primary_expression;
    return .{ .expression = expression, .arguments = arguments };
}

pub fn acceptSuperCall(self: *Parser) AcceptError!ast.SuperCall {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const super_token = try self.core.accept(RuleSet.is(.super));
    const arguments = try self.acceptArguments();

    if (!self.state.in_class_constructor) {
        try self.emitErrorAt(
            super_token.location,
            "'super()' is only allowed in class constructors",
            .{},
        );
        return error.UnexpectedToken;
    }

    return .{ .arguments = arguments };
}

pub fn acceptImportCall(self: *Parser) AcceptError!ast.ImportCall {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    _ = try self.core.accept(RuleSet.is(.import));
    _ = try self.core.accept(RuleSet.is(.@"("));
    const ctx: AcceptContext = .{ .precedence = getPrecedence(.@",") + 1 };
    const specifier_expression = try self.allocator.create(ast.Expression);
    errdefer self.allocator.destroy(specifier_expression);
    specifier_expression.* = try self.acceptExpression(ctx);
    _ = self.core.accept(RuleSet.is(.@",")) catch {};
    var options_expression: ?*ast.Expression = null;
    if (self.acceptExpression(ctx)) |expression| {
        options_expression = try self.allocator.create(ast.Expression);
        options_expression.?.* = expression;
        _ = self.core.accept(RuleSet.is(.@",")) catch {};
    } else |_| {}
    _ = try self.core.accept(RuleSet.is(.@")"));
    return .{
        .specifier_expression = specifier_expression,
        .options_expression = options_expression,
    };
}

pub fn acceptArguments(self: *Parser) AcceptError!ast.Arguments {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    var arguments: std.ArrayList(ast.Argument) = .empty;
    errdefer arguments.deinit(self.allocator);
    _ = try self.core.accept(RuleSet.is(.@"("));
    const ctx: AcceptContext = .{ .precedence = getPrecedence(.@",") + 1 };
    while (true) {
        if (self.acceptExpression(ctx)) |expression| {
            try arguments.append(self.allocator, .{ .expression = expression });
        } else |_| if (self.core.accept(RuleSet.is(.@"..."))) |_| {
            const expression = try self.acceptExpression(ctx);
            try arguments.append(self.allocator, .{ .spread = expression });
        } else |_| break;
        _ = self.core.accept(RuleSet.is(.@",")) catch break;
    }
    _ = try self.core.accept(RuleSet.is(.@")"));
    return arguments.toOwnedSlice(self.allocator);
}

pub fn acceptOptionalExpression(
    self: *Parser,
    primary_expression: ast.Expression,
) AcceptError!ast.OptionalExpression {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    var properties: std.ArrayList(ast.OptionalExpression.Property) = .empty;
    defer properties.deinit(self.allocator);

    _ = try self.core.accept(RuleSet.is(.@"?."));
    try properties.append(self.allocator, try self.acceptOptionalExpressionProperty());

    while (try self.core.peek()) |next_token| {
        const property = switch (next_token.type) {
            .@"(", .@"[" => try self.acceptOptionalExpressionProperty(),
            .@"." => blk: {
                _ = self.core.accept(RuleSet.is(.@".")) catch unreachable;
                break :blk try self.acceptOptionalExpressionProperty();
            },
            else => break,
        };
        try properties.append(self.allocator, property);
    }

    // Defer heap allocation of expression until we know this is an OptionalExpression
    const expression = try self.allocator.create(ast.Expression);
    expression.* = primary_expression;
    return .{ .expression = expression, .properties = try properties.toOwnedSlice(self.allocator) };
}

fn acceptOptionalExpressionProperty(self: *Parser) AcceptError!ast.OptionalExpression.Property {
    if (self.acceptArguments()) |arguments|
        return .{ .arguments = arguments }
    else |_| if (self.core.accept(RuleSet.is(.@"["))) |_| {
        const expr = try self.allocator.create(ast.Expression);
        errdefer self.allocator.destroy(expr);
        expr.* = try self.acceptExpression(.{});
        _ = try self.core.accept(RuleSet.is(.@"]"));
        return .{ .expression = expr };
    } else |_| if (self.acceptIdentifierName()) |identifier|
        return .{ .identifier = identifier }
    else |_| if (self.acceptPrivateIdentifier()) |private_identifier|
        return .{ .private_identifier = private_identifier }
    else |_|
        return error.UnexpectedToken;
}

pub fn acceptUpdateExpression(
    self: *Parser,
    primary_expression: ?ast.Expression,
) AcceptError!ast.UpdateExpression {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    if (primary_expression != null and self.followedByLineTerminator()) {
        return error.UnexpectedToken;
    }

    const operator_token = try self.core.accept(RuleSet.oneOf(.{ .@"++", .@"--" }));
    const operator: ast.UpdateExpression.Operator = switch (operator_token.type) {
        .@"++" => .@"++",
        .@"--" => .@"--",
        else => unreachable,
    };

    var @"type": ast.UpdateExpression.Type = undefined;

    // Defer heap allocation of expression until we know this is an UpdateExpression
    const expression = try self.allocator.create(ast.Expression);
    errdefer self.allocator.destroy(expression);
    if (primary_expression == null) {
        const ctx: AcceptContext = switch (operator_token.type) {
            .@"++" => .{ .precedence = getPrecedenceAlt(.prefix_increment), .associativity = getAssociativityAlt(.prefix_increment) },
            .@"--" => .{ .precedence = getPrecedenceAlt(.prefix_decrement), .associativity = getAssociativityAlt(.prefix_decrement) },
            else => unreachable,
        };
        expression.* = try self.acceptExpression(ctx);
        @"type" = .prefix;
    } else {
        expression.* = primary_expression.?;
        @"type" = .postfix;
    }

    // It is an early Syntax Error if the AssignmentTargetType of LeftHandSideExpression is invalid.
    if (@"type" == .prefix and expression.assignmentTargetType(self.state.in_strict_mode) == .invalid) {
        try self.emitErrorAt(state.location, "Invalid left-hand side in update expression", .{});
        return error.UnexpectedToken;
    }

    // It is an early Syntax Error if the AssignmentTargetType of UnaryExpression is invalid.
    if (@"type" == .postfix and expression.assignmentTargetType(self.state.in_strict_mode) == .invalid) {
        try self.emitErrorAt(state.location, "Invalid right-hand side in update expression", .{});
        return error.UnexpectedToken;
    }

    if (self.state.in_strict_mode and
        expression.* == .primary_expression and
        expression.primary_expression == .identifier_reference)
    {
        try self.ensureAllowedIdentifier(
            .identifier_reference,
            expression.primary_expression.identifier_reference,
            state.location,
        );
    }

    return .{
        .type = @"type",
        .operator = operator,
        .expression = expression,
    };
}

pub fn acceptLiteral(self: *Parser) AcceptError!ast.Literal {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    if (self.acceptNumericLiteral()) |numeric_literal|
        return .{ .numeric = numeric_literal }
    else |_| if (self.acceptStringLiteral()) |string_literal|
        return .{ .string = string_literal }
    else |_| if (self.core.accept(RuleSet.is(.null))) |_|
        return .null
    else |_| if (self.core.accept(RuleSet.is(.true))) |_|
        return .{ .boolean = true }
    else |_| if (self.core.accept(RuleSet.is(.false))) |_|
        return .{ .boolean = false }
    else |_|
        return error.UnexpectedToken;
}

pub fn acceptNumericLiteral(self: *Parser) AcceptError!ast.NumericLiteral {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const token = try self.core.accept(RuleSet.is(.numeric));
    var consumed: u32 = undefined;
    const literal = NewTokenizer.NumericLiteral.parse(token.text, &consumed).?;
    const production: ast.NumericLiteral.Production = if (literal.base == .octal and
        !(token.text.len >= 2 and (token.text[1] == 'o' or token.text[1] == 'O')))
        .legacy_octal_integer_literal
    else if (literal.base == .decimal and
        token.text.len >= 2 and token.text[0] == '0' and std.ascii.isDigit(token.text[1]))
        .non_octal_decimal_integer_literal
    else
        .regular;
    const numeric_literal: ast.NumericLiteral = .{
        .text = try self.allocator.dupe(u8, token.text),
        .system = literal.base,
        .production = production,
        .type = literal.kind,
    };

    switch (numeric_literal.production) {
        // DecimalIntegerLiteral :: NonOctalDecimalIntegerLiteral
        // NumericLiteral :: LegacyOctalIntegerLiteral
        .non_octal_decimal_integer_literal,
        .legacy_octal_integer_literal,
        => {
            // - It is a Syntax Error if IsStrict(this production) is true.
            if (self.state.in_strict_mode) {
                try self.emitErrorAt(
                    token.location,
                    "Numeric literal with leading zero is not allowed in strict mode",
                    .{},
                );
            }
        },
        .regular => {},
    }

    return numeric_literal;
}

pub fn acceptStringLiteral(self: *Parser) AcceptError!ast.StringLiteral {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const token = try self.core.accept(RuleSet.is(.string));
    const literal: NewTokenizer.StringLiteral = .{ .text = token.text };
    if (!literal.validate()) {
        try self.emitErrorAt(token.location, "Invalid escape sequence", .{});
        return error.UnexpectedToken;
    }
    return .{ .text = try self.allocator.dupe(u8, token.text) };
}

pub fn acceptArrayLiteral(self: *Parser) AcceptError!ast.ArrayLiteral {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    _ = try self.core.accept(RuleSet.is(.@"["));
    var elements: std.ArrayList(ast.ArrayLiteral.Element) = .empty;
    errdefer elements.deinit(self.allocator);
    const ctx: AcceptContext = .{ .precedence = getPrecedence(.@",") + 1 };
    while (true) {
        if (self.core.accept(RuleSet.is(.@"..."))) |_| {
            const expression = try self.acceptExpression(ctx);
            try elements.append(self.allocator, .{ .spread = expression });
            _ = self.core.accept(RuleSet.is(.@",")) catch break;
        } else |_| if (self.acceptExpression(ctx)) |expression| {
            try elements.append(self.allocator, .{ .expression = expression });
            _ = self.core.accept(RuleSet.is(.@",")) catch break;
        } else |_| if (self.core.accept(RuleSet.is(.@","))) |_| {
            try elements.append(self.allocator, .elision);
        } else |_| break;
    }
    _ = try self.core.accept(RuleSet.is(.@"]"));
    return .{ .element_list = try elements.toOwnedSlice(self.allocator) };
}

pub fn acceptObjectLiteral(self: *Parser) AcceptError!ast.ObjectLiteral {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    _ = try self.core.accept(RuleSet.is(.@"{"));
    const property_definition_list = try self.acceptPropertyDefinitionList();
    _ = try self.core.accept(RuleSet.is(.@"}"));
    return .{ .property_definition_list = property_definition_list };
}

pub fn acceptPropertyDefinitionList(self: *Parser) AcceptError!ast.PropertyDefinitionList {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    var property_definitions: std.ArrayList(ast.PropertyDefinition) = .empty;
    errdefer property_definitions.deinit(self.allocator);
    var has_proto_setter = false;
    while (self.acceptPropertyDefinition(&has_proto_setter)) |property_definition| {
        try property_definitions.append(self.allocator, property_definition);
        _ = self.core.accept(RuleSet.is(.@",")) catch break;
    } else |_| {}
    return .{ .items = try property_definitions.toOwnedSlice(self.allocator) };
}

pub fn acceptPropertyDefinition(self: *Parser, has_proto_setter: *bool) AcceptError!ast.PropertyDefinition {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const location = (try self.peekToken()).location;
    const ctx: AcceptContext = .{ .precedence = getPrecedence(.@",") + 1 };
    if (self.core.accept(RuleSet.is(.@"..."))) |_| {
        const expression = try self.acceptExpression(ctx);
        return .{ .spread = expression };
    } else |_| if (self.acceptMethodDefinition(null)) |method_definition| {
        return .{ .method_definition = method_definition };
    } else |_| if (self.acceptPropertyNameAndExpression(ctx, location, has_proto_setter)) |property_name_and_expression| {
        return .{ .property_name_and_expression = property_name_and_expression };
    } else |_| if (self.acceptIdentifierReference()) |identifier_reference| {
        return .{ .identifier_reference = identifier_reference };
    } else |_| return error.UnexpectedToken;
}

pub fn acceptPropertyName(self: *Parser) AcceptError!ast.PropertyName {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    if (self.acceptIdentifierName()) |identifier| {
        // LiteralPropertyName : IdentifierName
        return .{ .literal_property_name = .{ .identifier = identifier } };
    } else |_| if (self.acceptStringLiteral()) |string_literal| {
        // LiteralPropertyName : StringLiteral
        return .{ .literal_property_name = .{ .string_literal = string_literal } };
    } else |_| if (self.acceptNumericLiteral()) |numeric_literal| {
        // LiteralPropertyName : NumericLiteral
        return .{ .literal_property_name = .{ .numeric_literal = numeric_literal } };
    } else |_| if (self.core.accept(RuleSet.is(.@"["))) |_| {
        // ComputedPropertyName
        const computed_property_name = try self.acceptExpression(.{});
        _ = try self.core.accept(RuleSet.is(.@"]"));
        return .{ .computed_property_name = computed_property_name };
    } else |_| return error.UnexpectedToken;
}

pub fn acceptPropertyNameAndExpression(
    self: *Parser,
    ctx: AcceptContext,
    location: Location,
    has_proto_setter: *bool,
) AcceptError!ast.PropertyDefinition.PropertyNameAndExpression {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const property_name = try self.acceptPropertyName();
    _ = try self.core.accept(RuleSet.is(.@":"));
    const expression = try self.acceptExpression(ctx);
    const is_proto_setter = try property_name.eql(self.allocator, "__proto__");
    // It is a Syntax Error if the PropertyNameList of PropertyDefinitionList contains any
    // duplicate entries for "__proto__" and at least two of those entries were obtained
    // from productions of the form PropertyDefinition : PropertyName : AssignmentExpression.
    if (is_proto_setter) {
        if (has_proto_setter.*) {
            try self.emitErrorAt(location, "Object literal has duplicate '__proto__' property", .{});
            return error.UnexpectedToken;
        }
        has_proto_setter.* = true;
    }
    return .{
        .property_name = property_name,
        .expression = expression,
    };
}

pub fn acceptUnaryExpression(self: *Parser) AcceptError!ast.UnaryExpression {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const operator_token = try self.core.accept(RuleSet.oneOf(.{
        .delete,
        .void,
        .typeof,
        .@"+",
        .@"-",
        .@"~",
        .@"!",
    }));
    const operator: ast.UnaryExpression.Operator = switch (operator_token.type) {
        .delete => .delete,
        .void => .void,
        .typeof => .typeof,
        .@"+" => .@"+",
        .@"-" => .@"-",
        .@"~" => .@"~",
        .@"!" => .@"!",
        else => unreachable,
    };
    const ctx: AcceptContext = switch (operator_token.type) {
        .@"+" => .{ .precedence = getPrecedenceAlt(.unary_plus), .associativity = getAssociativityAlt(.unary_plus) },
        .@"-" => .{ .precedence = getPrecedenceAlt(.unary_minus), .associativity = getAssociativityAlt(.unary_minus) },
        else => .{ .precedence = getPrecedence(operator_token.type), .associativity = getAssociativity(operator_token.type) },
    };
    const expression = try self.allocator.create(ast.Expression);
    errdefer self.allocator.destroy(expression);
    expression.* = try self.acceptExpression(ctx);

    if (operator == .delete and self.state.in_strict_mode) {
        if (expression.* == .primary_expression and
            expression.primary_expression == .identifier_reference)
        {
            try self.emitErrorAt(
                operator_token.location,
                "Invalid use of 'delete' on identifier reference in strict mode",
                .{},
            );
        } else if (expression.endsWithPrivateIdentifier()) {
            try self.emitErrorAt(
                operator_token.location,
                "Invalid use of 'delete' on private identifier in strict mode",
                .{},
            );
        }
    }

    return .{ .operator = operator, .expression = expression };
}

pub fn acceptBinaryExpression(
    self: *Parser,
    primary_expression: ast.Expression,
    ctx: AcceptContext,
) AcceptError!ast.BinaryExpression {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const token = try self.core.accept(RuleSet.oneOf(.{
        .@"**",
        .@"*",
        .@"/",
        .@"%",
        .@"+",
        .@"-",
        .@"<<",
        .@">>",
        .@">>>",
        .@"&",
        .@"^",
        .@"|",
    }));
    const operator: ast.BinaryExpression.Operator = switch (token.type) {
        .@"**" => .@"**",
        .@"*" => .@"*",
        .@"/" => .@"/",
        .@"%" => .@"%",
        .@"+" => .@"+",
        .@"-" => .@"-",
        .@"<<" => .@"<<",
        .@">>" => .@">>",
        .@">>>" => .@">>>",
        .@"&" => .@"&",
        .@"^" => .@"^",
        .@"|" => .@"|",
        else => unreachable,
    };
    // Defer heap allocation of expression until we know this is a BinaryExpression
    const lhs_expression = try self.allocator.create(ast.Expression);
    errdefer self.allocator.destroy(lhs_expression);
    lhs_expression.* = primary_expression;
    const rhs_expression = try self.allocator.create(ast.Expression);
    errdefer self.allocator.destroy(rhs_expression);
    rhs_expression.* = try self.acceptExpression(ctx);
    return .{
        .operator = operator,
        .lhs_expression = lhs_expression,
        .rhs_expression = rhs_expression,
    };
}

pub fn acceptRelationalExpression(
    self: *Parser,
    primary_expression: union(enum) {
        expression: ast.Expression,
        private_identifier: ast.PrivateIdentifier,
    },
    ctx: AcceptContext,
) AcceptError!ast.RelationalExpression {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const token = switch (primary_expression) {
        .expression => try self.core.accept(RuleSet.oneOf(.{ .@">", .@"<", .@">=", .@"<=", .instanceof, .in })),
        .private_identifier => try self.core.accept(RuleSet.is(.in)),
    };
    const operator: ast.RelationalExpression.Operator = switch (token.type) {
        .@">" => .@">",
        .@"<" => .@"<",
        .@">=" => .@">=",
        .@"<=" => .@"<=",
        .instanceof => .instanceof,
        .in => .in,
        else => unreachable,
    };
    // Defer heap allocation of expression until we know this is a RelationalExpression
    const lhs: ast.RelationalExpression.Lhs = switch (primary_expression) {
        .expression => |expression| .{
            .expression = blk: {
                const lhs_expression = try self.allocator.create(ast.Expression);
                errdefer self.allocator.destroy(lhs_expression);
                lhs_expression.* = expression;
                break :blk lhs_expression;
            },
        },
        .private_identifier => |private_identifier| .{ .private_identifier = private_identifier },
    };
    const rhs_expression = try self.allocator.create(ast.Expression);
    errdefer self.allocator.destroy(rhs_expression);
    rhs_expression.* = try self.acceptExpression(ctx);
    return .{
        .operator = operator,
        .lhs = lhs,
        .rhs_expression = rhs_expression,
    };
}

pub fn acceptEqualityExpression(
    self: *Parser,
    primary_expression: ast.Expression,
    ctx: AcceptContext,
) AcceptError!ast.EqualityExpression {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const token = try self.core.accept(RuleSet.oneOf(.{ .@"==", .@"!=", .@"===", .@"!==" }));
    const operator: ast.EqualityExpression.Operator = switch (token.type) {
        .@"==" => .@"==",
        .@"!=" => .@"!=",
        .@"===" => .@"===",
        .@"!==" => .@"!==",
        else => unreachable,
    };
    // Defer heap allocation of expression until we know this is an EqualityExpression
    const lhs_expression = try self.allocator.create(ast.Expression);
    errdefer self.allocator.destroy(lhs_expression);
    lhs_expression.* = primary_expression;
    const rhs_expression = try self.allocator.create(ast.Expression);
    errdefer self.allocator.destroy(rhs_expression);
    rhs_expression.* = try self.acceptExpression(ctx);
    return .{
        .operator = operator,
        .lhs_expression = lhs_expression,
        .rhs_expression = rhs_expression,
    };
}

pub fn acceptLogicalExpression(
    self: *Parser,
    primary_expression: ast.Expression,
    ctx: AcceptContext,
) AcceptError!ast.LogicalExpression {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const token = try self.core.accept(RuleSet.oneOf(.{ .@"&&", .@"||", .@"??" }));
    const operator: ast.LogicalExpression.Operator = switch (token.type) {
        .@"&&" => .@"&&",
        .@"||" => .@"||",
        .@"??" => .@"??",
        else => unreachable,
    };
    // Defer heap allocation of expression until we know this is a LogicalExpression
    const lhs_expression = try self.allocator.create(ast.Expression);
    errdefer self.allocator.destroy(lhs_expression);
    lhs_expression.* = primary_expression;
    const rhs_expression = try self.allocator.create(ast.Expression);
    errdefer self.allocator.destroy(rhs_expression);
    rhs_expression.* = try self.acceptExpression(ctx);
    return .{
        .operator = operator,
        .lhs_expression = lhs_expression,
        .rhs_expression = rhs_expression,
    };
}

pub fn acceptConditionalExpression(
    self: *Parser,
    primary_expression: ast.Expression,
    ctx: AcceptContext,
) AcceptError!ast.ConditionalExpression {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    _ = try self.core.accept(RuleSet.is(.@"?"));
    // Defer heap allocation of expression until we know this is a ConditionalExpression
    const test_expression = try self.allocator.create(ast.Expression);
    errdefer self.allocator.destroy(test_expression);
    test_expression.* = primary_expression;
    const consequent_expression = try self.allocator.create(ast.Expression);
    errdefer self.allocator.destroy(consequent_expression);
    consequent_expression.* = try self.acceptExpression(ctx);
    _ = try self.core.accept(RuleSet.is(.@":"));
    const alternate_expression = try self.allocator.create(ast.Expression);
    errdefer self.allocator.destroy(alternate_expression);
    alternate_expression.* = try self.acceptExpression(ctx);
    return .{
        .test_expression = test_expression,
        .consequent_expression = consequent_expression,
        .alternate_expression = alternate_expression,
    };
}

pub fn acceptAssignmentExpression(
    self: *Parser,
    primary_expression: ast.Expression,
    ctx: AcceptContext,
) AcceptError!ast.AssignmentExpression {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    // TODO: Pass this in, here it points after the LHS
    const primary_expression_location = state.location;

    const token = try self.core.accept(RuleSet.oneOf(.{
        .@"=",
        .@"*=",
        .@"/=",
        .@"%=",
        .@"+=",
        .@"-=",
        .@"<<=",
        .@">>=",
        .@">>>=",
        .@"&=",
        .@"^=",
        .@"|=",
        .@"**=",
        .@"&&=",
        .@"||=",
        .@"??=",
    }));
    const operator: ast.AssignmentExpression.Operator = switch (token.type) {
        .@"=" => .@"=",
        .@"*=" => .@"*=",
        .@"/=" => .@"/=",
        .@"%=" => .@"%=",
        .@"+=" => .@"+=",
        .@"-=" => .@"-=",
        .@"<<=" => .@"<<=",
        .@">>=" => .@">>=",
        .@">>>=" => .@">>>=",
        .@"&=" => .@"&=",
        .@"^=" => .@"^=",
        .@"|=" => .@"|=",
        .@"**=" => .@"**=",
        .@"&&=" => .@"&&=",
        .@"||=" => .@"||=",
        .@"??=" => .@"??=",
        else => unreachable,
    };

    const invalid_lhs = switch (operator) {
        // AssignmentExpression : LeftHandSideExpression = AssignmentExpression
        .@"=" => blk: {
            // If LeftHandSideExpression is neither an ObjectLiteral nor an ArrayLiteral, it is a
            // Syntax Error if the AssignmentTargetType of LeftHandSideExpression is invalid.
            break :blk primary_expression != .assignment_pattern and
                primary_expression.assignmentTargetType(self.state.in_strict_mode) == .invalid;
        },

        // AssignmentExpression :
        //     LeftHandSideExpression AssignmentOperator AssignmentExpression
        .@"*=", .@"/=", .@"%=", .@"+=", .@"-=", .@"<<=", .@">>=", .@">>>=", .@"&=", .@"^=", .@"|=", .@"**=" => blk: {
            // It is a Syntax Error if the AssignmentTargetType of LeftHandSideExpression is invalid.
            break :blk primary_expression.assignmentTargetType(self.state.in_strict_mode) == .invalid;
        },

        // AssignmentExpression :
        //     LeftHandSideExpression &&= AssignmentExpression
        //     LeftHandSideExpression ||= AssignmentExpression
        //     LeftHandSideExpression ??= AssignmentExpression
        .@"&&=", .@"||=", .@"??=" => blk: {
            // It is a Syntax Error if the AssignmentTargetType of LeftHandSideExpression is not
            // simple.
            break :blk primary_expression.assignmentTargetType(self.state.in_strict_mode) != .simple;
        },
    };

    if (invalid_lhs) {
        try self.emitErrorAt(
            primary_expression_location,
            "Invalid left-hand side in assignment expression",
            .{},
        );
        return error.UnexpectedToken;
    }

    if (self.state.in_strict_mode and
        primary_expression == .primary_expression and
        primary_expression.primary_expression == .identifier_reference)
    {
        try self.ensureAllowedIdentifier(
            .identifier_reference,
            primary_expression.primary_expression.identifier_reference,
            primary_expression_location,
        );
    }

    // Defer heap allocation of expression until we know this is an AssignmentExpression
    const lhs_expression = try self.allocator.create(ast.Expression);
    errdefer self.allocator.destroy(lhs_expression);
    lhs_expression.* = primary_expression;
    const rhs_expression = try self.allocator.create(ast.Expression);
    errdefer self.allocator.destroy(rhs_expression);
    rhs_expression.* = try self.acceptExpression(ctx);
    return .{
        .operator = operator,
        .lhs_expression = lhs_expression,
        .rhs_expression = rhs_expression,
    };
}

pub fn acceptSequenceExpression(
    self: *Parser,
    primary_expression: ast.Expression,
) AcceptError!ast.SequenceExpression {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const ctx: AcceptContext = .{ .precedence = getPrecedence(.@",") + 1 };
    var expressions: std.ArrayList(ast.Expression) = .empty;
    errdefer expressions.deinit(self.allocator);
    while (self.core.accept(RuleSet.is(.@","))) |_| {
        const expression = try self.acceptExpression(ctx);
        try expressions.append(self.allocator, expression);
    } else |_| if (expressions.items.len == 0) return error.UnexpectedToken;
    try expressions.insert(self.allocator, 0, primary_expression);
    return .{ .expressions = try expressions.toOwnedSlice(self.allocator) };
}

pub fn acceptTaggedTemplate(
    self: *Parser,
    primary_expression: ast.Expression,
) AcceptError!ast.TaggedTemplate {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const template_literal = try self.acceptTemplateLiteral(true);

    // Defer heap allocation of expression until we know this is a TaggedTemplate
    const expression = try self.allocator.create(ast.Expression);
    expression.* = primary_expression;
    return .{ .expression = expression, .template_literal = template_literal };
}

pub fn acceptExpression(self: *Parser, ctx: AcceptContext) AcceptError!ast.Expression {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    var next_token = try self.peekToken();
    var expression: ast.Expression = switch (next_token.type) {
        .delete, .void, .typeof, .@"+", .@"-", .@"~", .@"!" => .{ .unary_expression = try self.acceptUnaryExpression() },
        .@"++", .@"--" => .{ .update_expression = try self.acceptUpdateExpression(null) },
        .new => if (self.acceptNewExpression()) |new_expression|
            .{ .new_expression = new_expression }
        else |_| if (self.acceptMetaProperty()) |meta_property|
            .{ .meta_property = meta_property }
        else |_|
            return error.UnexpectedToken,
        .super => if (self.acceptSuperCall()) |super_call|
            .{ .super_call = super_call }
        else |_| if (self.acceptSuperProperty()) |super_property|
            .{ .super_property = super_property }
        else |_|
            return error.UnexpectedToken,
        .import => if (self.acceptImportCall()) |import_call|
            .{ .import_call = import_call }
        else |_| if (self.acceptMetaProperty()) |meta_property|
            .{ .meta_property = meta_property }
        else |_|
            return error.UnexpectedToken,
        .private_identifier => blk: {
            const private_identifier = try self.acceptPrivateIdentifier();
            break :blk .{
                .relational_expression = try acceptRelationalExpression(
                    self,
                    .{ .private_identifier = private_identifier },
                    ctx,
                ),
            };
        },
        .@"{", .@"[" => blk: {
            const tmp_state = self.core.saveState();
            const error_count = self.diagnostics.errors.items.len;
            if (self.acceptAssignmentPattern()) |assignment_pattern| {
                if (try self.core.peek()) |next_token_| switch (next_token_.type) {
                    // Assignment expression LHS
                    .@"=",
                    .@"*=",
                    .@"/=",
                    .@"%=",
                    .@"+=",
                    .@"-=",
                    .@"<<=",
                    .@">>=",
                    .@">>>=",
                    .@"&=",
                    .@"^=",
                    .@"|=",
                    .@"**=",
                    .@"&&=",
                    .@"||=",
                    .@"??=",
                    => break :blk .{ .assignment_pattern = assignment_pattern },
                    .identifier,
                    => if (std.mem.eql(u8, next_token_.text, "of")) {
                        break :blk .{ .assignment_pattern = assignment_pattern };
                    },
                    // For loop initializer
                    .in => if (std.mem.findScalar(Tokenizer.TokenType, ctx.forbidden, .in) != null) {
                        break :blk .{ .assignment_pattern = assignment_pattern };
                    },
                    else => {},
                };
            } else |_| {}
            self.core.restoreState(tmp_state);
            // If parsing the assignment pattern failed we may have emitted an 'invalid assignment
            // target' error, e.g. for `"use strict"; ({ foo: eval })` - get rid of those
            while (self.diagnostics.errors.items.len > error_count) _ = self.diagnostics.errors.pop();
            const primary_expression = try self.acceptPrimaryExpression();
            break :blk .{ .primary_expression = primary_expression };
        },
        .@"(" => if (self.acceptPrimaryExpression()) |primary_expression|
            // Arrow function
            .{ .primary_expression = primary_expression }
        else |_| blk: {
            // Parenthesized expression
            _ = try self.core.accept(RuleSet.is(.@"("));
            const e = try self.acceptExpression(.{});
            _ = try self.core.accept(RuleSet.is(.@")"));
            break :blk e;
        },
        else => if (self.acceptAwaitExpression()) |await_expression|
            .{ .await_expression = await_expression }
        else |_| if (self.acceptYieldExpression()) |yield_expression|
            .{ .yield_expression = yield_expression }
        else |_| if (self.acceptPrimaryExpression()) |primary_expression|
            .{ .primary_expression = primary_expression }
        else |_|
            return error.UnexpectedToken,
    };

    if ((self.state.in_formal_parameters or self.state.in_function_body) and
        expression == .primary_expression and
        expression.primary_expression == .identifier_reference and
        (std.mem.eql(u8, expression.primary_expression.identifier_reference, "arguments") or
            std.mem.eql(u8, expression.primary_expression.identifier_reference, "eval")))
    {
        self.state.arguments_object_needed = true;
    }

    outer: while (true) {
        next_token = try self.core.peek() orelse break;
        while (next_token.type == .template or next_token.type == .template_head) {
            const copy = expression; // PRO footgun (https://github.com/ziglang/zig/issues/5973)
            expression = .{ .tagged_template = try self.acceptTaggedTemplate(copy) };
            next_token = try self.core.peek() orelse break :outer;
        }

        const new_ctx: AcceptContext = .{
            .precedence = getPrecedence(next_token.type),
            .associativity = getAssociativity(next_token.type),
            .forbidden = ctx.forbidden,
        };
        if (new_ctx.precedence < ctx.precedence) break;
        if (new_ctx.precedence == ctx.precedence and
            ctx.associativity != null and
            ctx.associativity.? == .left_to_right) break;
        if (std.mem.findScalar(
            Tokenizer.TokenType,
            new_ctx.forbidden,
            next_token.type,
        ) != null) break;
        expression = self.acceptSecondaryExpression(expression, new_ctx) catch break;
    }
    return expression;
}

pub fn acceptStatement(self: *Parser) AcceptError!*ast.Statement {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const statement = try self.allocator.create(ast.Statement);
    errdefer self.allocator.destroy(statement);

    const next_token = try self.peekToken();
    statement.* = switch (next_token.type) {
        .@"{" => .{ .block_statement = try self.acceptBlockStatement() },
        .@"var" => .{ .variable_statement = try self.acceptVariableStatement(false) },
        .@"if" => .{ .if_statement = try self.acceptIfStatement() },
        .do, .@"while", .@"for", .@"switch" => .{ .breakable_statement = try self.acceptBreakableStatement() },
        .@"continue" => .{ .continue_statement = try self.acceptContinueStatement() },
        .@"break" => .{ .break_statement = try self.acceptBreakStatement() },
        .@"return" => .{ .return_statement = try self.acceptReturnStatement() },
        .with => .{ .with_statement = try self.acceptWithStatement() },
        .throw => .{ .throw_statement = try self.acceptThrowStatement() },
        .@"try" => .{ .try_statement = try self.acceptTryStatement() },
        .debugger => .{ .debugger_statement = try self.acceptDebuggerStatement() },
        .@";" => blk: {
            _ = self.core.accept(RuleSet.is(.@";")) catch unreachable;
            break :blk .empty_statement;
        },
        else => if (self.acceptLabelledStatement()) |labelled_statement|
            .{ .labelled_statement = labelled_statement }
        else |_| if (self.acceptExpressionStatement()) |expression_statement|
            .{ .expression_statement = expression_statement }
        else |_|
            return error.UnexpectedToken,
    };

    return statement;
}

pub fn acceptDeclaration(self: *Parser) AcceptError!*ast.Declaration {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const declaration = try self.allocator.create(ast.Declaration);
    errdefer self.allocator.destroy(declaration);

    if (self.acceptHoistableDeclaration()) |hoistable_declaration|
        declaration.* = .{ .hoistable_declaration = hoistable_declaration }
    else |_| if (self.acceptClassDeclaration()) |class_declaration|
        declaration.* = .{ .class_declaration = class_declaration }
    else |_| if (self.acceptLexicalDeclaration(false)) |lexical_declaration|
        declaration.* = .{ .lexical_declaration = lexical_declaration }
    else |_|
        return error.UnexpectedToken;
    return declaration;
}

pub fn acceptHoistableDeclaration(self: *Parser) AcceptError!ast.HoistableDeclaration {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    if (self.acceptFunctionDeclaration()) |function_declaration|
        return .{ .function_declaration = function_declaration }
    else |_| if (self.acceptGeneratorDeclaration()) |generator_declaration|
        return .{ .generator_declaration = generator_declaration }
    else |_| if (self.acceptAsyncFunctionDeclaration()) |async_function_declaration|
        return .{ .async_function_declaration = async_function_declaration }
    else |_| if (self.acceptAsyncGeneratorDeclaration()) |async_generator_declaration|
        return .{ .async_generator_declaration = async_generator_declaration }
    else |_|
        return error.UnexpectedToken;
}

pub fn acceptBreakableStatement(self: *Parser) AcceptError!ast.BreakableStatement {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const tmp = temporaryChange(&self.state.in_breakable_statement, true);
    defer tmp.restore();

    if (self.acceptIterationStatement()) |iteration_statement|
        return .{ .iteration_statement = iteration_statement }
    else |_| if (self.acceptSwitchStatement()) |switch_statement|
        return .{ .switch_statement = switch_statement }
    else |_|
        return error.UnexpectedToken;
}

pub fn acceptBlockStatement(self: *Parser) AcceptError!ast.BlockStatement {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    return .{ .block = try self.acceptBlock() };
}

pub fn acceptBlock(self: *Parser) AcceptError!ast.Block {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const token = try self.core.accept(RuleSet.is(.@"{"));
    const statement_list = try self.acceptStatementList(.{});
    const block: ast.Block = .{ .statement_list = statement_list };
    _ = try self.core.accept(RuleSet.is(.@"}"));

    var lexically_declared_names = IdentifierStackRange.open(self);
    defer lexically_declared_names.deinit();
    try statement_list.collectLexicallyDeclaredNames(self.allocator, &self.identifier_stack);
    lexically_declared_names.close();

    var var_declared_names = IdentifierStackRange.open(self);
    defer var_declared_names.deinit();
    try statement_list.collectVarDeclaredNames(self.allocator, &self.identifier_stack);
    var_declared_names.close();

    // - It is a Syntax Error if the LexicallyDeclaredNames of StatementList contains any duplicate
    //   entries, unless the host is a web browser or otherwise supports Block-Level Function
    //   Declarations Web Legacy Compatibility Semantics, and both of the following conditions are
    //   true:
    //     - IsStrict(this production) is false.
    //     - The duplicate entries are only bound by FunctionDeclarations.
    // - It is a Syntax Error if any element of the LexicallyDeclaredNames of StatementList also
    //   occurs in the VarDeclaredNames of StatementList.
    try self.ensureUniqueLexicallyDeclaredNames(
        lexically_declared_names.slice(),
        var_declared_names.slice(),
        token.location,
    );

    return block;
}

pub fn acceptStatementList(self: *Parser, ctx: AcceptContext) AcceptError!ast.StatementList {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const tmp = temporaryChange(&self.state.in_strict_mode, self.state.in_strict_mode);
    defer tmp.restore();
    var look_for_use_strict = ctx.update_strict_mode and !self.state.in_strict_mode;

    var statement_list_items: std.ArrayList(ast.StatementListItem) = .empty;
    errdefer statement_list_items.deinit(self.allocator);
    while (self.acceptStatementListItem()) |statement_list_item| {
        try statement_list_items.append(self.allocator, statement_list_item);
        if (look_for_use_strict) {
            if (!statement_list_item.analyze(.is_string_literal)) {
                look_for_use_strict = false;
                continue;
            }
            const statement_list: ast.StatementList = .{ .items = statement_list_items.items };
            self.state.in_strict_mode = statement_list.containsDirective("use strict");
        }
    } else |_| {}
    return .{ .items = try statement_list_items.toOwnedSlice(self.allocator) };
}

pub fn acceptStatementListItem(self: *Parser) AcceptError!ast.StatementListItem {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    // NOTE: Declarations need to be tried first since function declarations could also be expressions
    if (self.acceptDeclaration()) |declaration|
        return .{ .declaration = declaration }
    else |_| if (self.acceptStatement()) |statement|
        return .{ .statement = statement }
    else |_|
        return error.UnexpectedToken;
}

pub fn acceptLexicalDeclaration(
    self: *Parser,
    for_initializer: bool,
) AcceptError!ast.LexicalDeclaration {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const @"type": ast.LexicalDeclaration.Type = if (self.acceptKeyword("let")) |_|
        .let
    else |_| if (self.core.accept(RuleSet.is(.@"const"))) |_|
        .@"const"
    else |_| if (self.acceptKeyword("using")) |_| blk: {
        if (self.followedByLineTerminator()) return error.UnexpectedToken;
        break :blk .using;
    } else |_| if (self.core.accept(RuleSet.is(.await))) |_| blk: {
        if (self.followedByLineTerminator()) return error.UnexpectedToken;
        _ = try self.acceptKeyword("using");
        if (self.followedByLineTerminator()) return error.UnexpectedToken;
        break :blk .await_using;
    } else |_| return error.UnexpectedToken;

    const binding_list = try self.acceptBindingList();
    if (!for_initializer) try self.acceptOrInsertSemicolon();

    var bound_names = IdentifierStackRange.open(self);
    defer bound_names.deinit();
    try binding_list.collectBoundNames(self.allocator, &self.identifier_stack);
    bound_names.close();

    // It is a Syntax Error if the BoundNames of BindingList contains "let".
    if (containsSlice(bound_names.slice(), "let")) {
        try self.emitErrorAt(
            state.location,
            "Lexical declaration must not have binding named 'let'",
            .{},
        );
    }

    // It is a Syntax Error if the BoundNames of BindingList contains any duplicate entries.
    try self.ensureUniqueBoundNames(.lexical_declaration, bound_names.slice(), state.location);

    switch (@"type") {
        .@"const" => for (binding_list.items) |binding| switch (binding) {
            .binding_identifier => |binding_identifier| if (!for_initializer and binding_identifier.initializer == null) {
                try self.emitErrorAt(
                    state.location,
                    "'const' declaration must have an initializer",
                    .{},
                );
                return error.UnexpectedToken;
            },
            else => {},
        },
        .using, .await_using => for (binding_list.items) |binding| switch (binding) {
            .binding_identifier => |binding_identifier| if (!for_initializer and binding_identifier.initializer == null) {
                try self.emitErrorAt(
                    state.location,
                    "'using' and 'await using' declarations must have an initializer",
                    .{},
                );
                return error.UnexpectedToken;
            },
            .binding_pattern => {
                try self.emitErrorAt(
                    state.location,
                    "'using' and 'await using' declarations must not contain binding pattern",
                    .{},
                );
                return error.UnexpectedToken;
            },
        },
        else => {},
    }

    return .{ .type = @"type", .binding_list = binding_list };
}

pub fn acceptBindingList(self: *Parser) AcceptError!ast.BindingList {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    var lexical_bindings: std.ArrayList(ast.LexicalBinding) = .empty;
    errdefer lexical_bindings.deinit(self.allocator);
    while (self.acceptLexicalBinding()) |lexical_binding| {
        try lexical_bindings.append(self.allocator, lexical_binding);
        _ = self.core.accept(RuleSet.is(.@",")) catch break;
    } else |_| {}
    if (lexical_bindings.items.len == 0) return error.UnexpectedToken;
    return .{ .items = try lexical_bindings.toOwnedSlice(self.allocator) };
}

pub fn acceptLexicalBinding(self: *Parser) AcceptError!ast.LexicalBinding {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const ctx: AcceptContext = .{ .precedence = getPrecedence(.@",") + 1 };
    if (self.acceptBindingIdentifier()) |binding_identifier| {
        var initializer: ?ast.Expression = null;
        if (self.core.accept(RuleSet.is(.@"="))) |_| {
            initializer = try self.acceptExpression(ctx);
        } else |_| {}
        return .{
            .binding_identifier = .{
                .binding_identifier = binding_identifier,
                .initializer = initializer,
            },
        };
    } else |_| if (self.acceptBindingPattern()) |binding_pattern| {
        _ = try self.core.accept(RuleSet.is(.@"="));
        const initializer = try self.acceptExpression(ctx);
        return .{
            .binding_pattern = .{
                .binding_pattern = binding_pattern,
                .initializer = initializer,
            },
        };
    } else |_| return error.UnexpectedToken;
}

pub fn acceptVariableStatement(
    self: *Parser,
    for_initializer: bool,
) AcceptError!ast.VariableStatement {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    _ = try self.core.accept(RuleSet.is(.@"var"));
    const variable_declaration_list = try self.acceptVariableDeclarationList();
    if (!for_initializer) try self.acceptOrInsertSemicolon();
    return .{ .variable_declaration_list = variable_declaration_list };
}

pub fn acceptVariableDeclarationList(self: *Parser) AcceptError!ast.VariableDeclarationList {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    var variable_declarations: std.ArrayList(ast.VariableDeclaration) = .empty;
    errdefer variable_declarations.deinit(self.allocator);
    while (self.acceptVariableDeclaration()) |variable_declaration| {
        try variable_declarations.append(self.allocator, variable_declaration);
        _ = self.core.accept(RuleSet.is(.@",")) catch break;
    } else |_| {}
    if (variable_declarations.items.len == 0) return error.UnexpectedToken;
    return .{ .items = try variable_declarations.toOwnedSlice(self.allocator) };
}

pub fn acceptVariableDeclaration(self: *Parser) AcceptError!ast.VariableDeclaration {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const ctx: AcceptContext = .{ .precedence = getPrecedence(.@",") + 1 };
    if (self.acceptBindingIdentifier()) |binding_identifier| {
        var initializer: ?ast.Expression = null;
        if (self.core.accept(RuleSet.is(.@"="))) |_| {
            initializer = try self.acceptExpression(ctx);
        } else |_| {}
        return .{
            .binding_identifier = .{
                .binding_identifier = binding_identifier,
                .initializer = initializer,
            },
        };
    } else |_| if (self.acceptBindingPattern()) |binding_pattern| {
        _ = try self.core.accept(RuleSet.is(.@"="));
        const initializer = try self.acceptExpression(ctx);
        return .{
            .binding_pattern = .{
                .binding_pattern = binding_pattern,
                .initializer = initializer,
            },
        };
    } else |_| return error.UnexpectedToken;
}

pub fn acceptAssignmentPattern(self: *Parser) AcceptError!ast.AssignmentPattern {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    if (self.acceptObjectAssignmentPattern()) |object_assignment_pattern|
        return .{ .object_assignment_pattern = object_assignment_pattern }
    else |_| if (self.acceptArrayAssignmentPattern()) |array_assignment_pattern|
        return .{ .array_assignment_pattern = array_assignment_pattern }
    else |_|
        return error.UnexpectedToken;
}

pub fn acceptObjectAssignmentPattern(self: *Parser) AcceptError!ast.ObjectAssignmentPattern {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    var properties: std.ArrayList(ast.ObjectAssignmentPattern.Property) = .empty;
    _ = try self.core.accept(RuleSet.is(.@"{"));
    while (true) {
        if (self.acceptAssignmentProperty()) |assignment_property| {
            try properties.append(self.allocator, .{ .assignment_property = assignment_property });
            _ = self.core.accept(RuleSet.is(.@",")) catch break;
        } else |_| if (self.acceptAssignmentRestProperty()) |rest_property| {
            try properties.append(self.allocator, .{ .assignment_rest_property = rest_property });
            break;
        } else |_| break;
    }
    _ = try self.core.accept(RuleSet.is(.@"}"));
    return .{ .properties = try properties.toOwnedSlice(self.allocator) };
}

pub fn acceptArrayAssignmentPattern(self: *Parser) AcceptError!ast.ArrayAssignmentPattern {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    var elements: std.ArrayList(ast.ArrayAssignmentPattern.Element) = .empty;
    _ = try self.core.accept(RuleSet.is(.@"["));
    while (true) {
        if (self.acceptAssignmentElement()) |assignment_element| {
            try elements.append(self.allocator, .{ .assignment_element = assignment_element });
            _ = self.core.accept(RuleSet.is(.@",")) catch break;
        } else |_| if (self.acceptAssignmentRestElement()) |rest_element| {
            try elements.append(self.allocator, .{ .assignment_rest_element = rest_element });
            if (self.core.accept(RuleSet.is(.@","))) |token| {
                try self.emitErrorAt(token.location, "Rest element must not be followed by comma", .{});
            } else |_| {}
            break;
        } else |_| if (self.core.accept(RuleSet.is(.@","))) |_| {
            try elements.append(self.allocator, .elision);
        } else |_| break;
    }
    _ = try self.core.accept(RuleSet.is(.@"]"));
    return .{ .elements = try elements.toOwnedSlice(self.allocator) };
}

pub fn acceptAssignmentRestProperty(self: *Parser) AcceptError!ast.AssignmentRestProperty {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    _ = try self.core.accept(RuleSet.is(.@"..."));
    const destructuring_assignment_target = try self.acceptDestructuringAssignmentTarget();
    return .{ .destructuring_assignment_target = destructuring_assignment_target };
}

pub fn acceptAssignmentProperty(self: *Parser) AcceptError!ast.AssignmentProperty {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const property_name = try self.acceptPropertyName();
    if (self.core.accept(RuleSet.is(.@":"))) |_| {
        const assignment_element = try self.acceptAssignmentElement();
        return .{
            .property_name_and_assignment_element = .{
                .property_name = property_name,
                .assignment_element = assignment_element,
            },
        };
    } else |_| {}

    self.core.restoreState(state);
    const identifier_reference = try self.acceptIdentifierReference();
    const ctx: AcceptContext = .{ .precedence = getPrecedence(.@",") + 1 };
    const initializer = if (self.core.accept(RuleSet.is(.@"="))) |_|
        try self.acceptExpression(ctx)
    else |_|
        null;
    return .{
        .identifier_reference_and_expression = .{
            .identifier_reference = identifier_reference,
            .initializer = initializer,
        },
    };
}

pub fn acceptAssignmentElement(self: *Parser) AcceptError!ast.AssignmentElement {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const destructuring_assignment_target = try self.acceptDestructuringAssignmentTarget();
    const ctx: AcceptContext = .{ .precedence = getPrecedence(.@",") + 1 };
    const initializer = if (self.core.accept(RuleSet.is(.@"="))) |_|
        try self.acceptExpression(ctx)
    else |_|
        null;
    return .{
        .destructuring_assignment_target = destructuring_assignment_target,
        .initializer = initializer,
    };
}

pub fn acceptAssignmentRestElement(self: *Parser) AcceptError!ast.AssignmentRestElement {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    _ = try self.core.accept(RuleSet.is(.@"..."));
    const destructuring_assignment_target = try self.acceptDestructuringAssignmentTarget();
    return .{ .destructuring_assignment_target = destructuring_assignment_target };
}

pub fn acceptDestructuringAssignmentTarget(self: *Parser) AcceptError!ast.DestructuringAssignmentTarget {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    if (self.acceptAssignmentPattern()) |assignment_pattern|
        return .{ .assignment_pattern = assignment_pattern }
    else |_| {}

    var expression: ast.Expression = if (self.acceptSuperProperty()) |super_property|
        .{ .super_property = super_property }
    else |_| if (self.acceptIdentifierReference()) |identifier_reference|
        .{ .primary_expression = .{ .identifier_reference = identifier_reference } }
    else |_|
        return error.UnexpectedToken;

    while (true) {
        const member_expression = self.acceptMemberExpression(expression) catch break;
        expression = .{ .member_expression = member_expression };
    }

    // - If LeftHandSideExpression is neither an ObjectLiteral nor an ArrayLiteral, it is a Syntax
    //   Error if the AssignmentTargetType of LeftHandSideExpression is not simple.
    if (expression.assignmentTargetType(self.state.in_strict_mode) != .simple) {
        try self.emitErrorAt(state.location, "Invalid destructuring assignment target", .{});
        return error.UnexpectedToken;
    }

    return switch (expression) {
        .super_property => |super_property| .{ .super_property = super_property },
        .primary_expression => .{ .identifier_reference = expression.primary_expression.identifier_reference },
        .member_expression => |member_expression| .{ .member_expression = member_expression },
        else => unreachable,
    };
}

pub fn acceptBindingPattern(self: *Parser) AcceptError!ast.BindingPattern {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    if (self.acceptObjectBindingPattern()) |object_binding_pattern|
        return .{ .object_binding_pattern = object_binding_pattern }
    else |_| if (self.acceptArrayBindingPattern()) |array_binding_pattern|
        return .{ .array_binding_pattern = array_binding_pattern }
    else |_|
        return error.UnexpectedToken;
}

pub fn acceptObjectBindingPattern(self: *Parser) AcceptError!ast.ObjectBindingPattern {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    var properties: std.ArrayList(ast.ObjectBindingPattern.Property) = .empty;
    _ = try self.core.accept(RuleSet.is(.@"{"));
    while (true) {
        if (self.acceptBindingProperty()) |binding_property| {
            try properties.append(self.allocator, .{ .binding_property = binding_property });
            _ = self.core.accept(RuleSet.is(.@",")) catch break;
        } else |_| if (self.acceptBindingRestProperty()) |binding_rest_property| {
            try properties.append(self.allocator, .{ .binding_rest_property = binding_rest_property });
            break;
        } else |_| break;
    }
    _ = try self.core.accept(RuleSet.is(.@"}"));
    return .{ .properties = try properties.toOwnedSlice(self.allocator) };
}

pub fn acceptArrayBindingPattern(self: *Parser) AcceptError!ast.ArrayBindingPattern {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    var elements: std.ArrayList(ast.ArrayBindingPattern.Element) = .empty;
    _ = try self.core.accept(RuleSet.is(.@"["));
    while (true) {
        if (self.acceptBindingElement()) |binding_element| {
            try elements.append(self.allocator, .{ .binding_element = binding_element });
            _ = self.core.accept(RuleSet.is(.@",")) catch break;
        } else |_| if (self.acceptBindingRestElement()) |binding_rest_element| {
            try elements.append(self.allocator, .{ .binding_rest_element = binding_rest_element });
            if (self.core.accept(RuleSet.is(.@","))) |token| {
                try self.emitErrorAt(token.location, "Rest element must not be followed by comma", .{});
            } else |_| {}
            break;
        } else |_| if (self.core.accept(RuleSet.is(.@","))) |_| {
            try elements.append(self.allocator, .elision);
        } else |_| break;
    }
    _ = try self.core.accept(RuleSet.is(.@"]"));
    return .{ .elements = try elements.toOwnedSlice(self.allocator) };
}

pub fn acceptBindingRestProperty(self: *Parser) AcceptError!ast.BindingRestProperty {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    _ = try self.core.accept(RuleSet.is(.@"..."));
    const binding_identifier = try self.acceptBindingIdentifier();
    return .{ .binding_identifier = binding_identifier };
}

pub fn acceptBindingProperty(self: *Parser) AcceptError!ast.BindingProperty {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    if (self.acceptPropertyName()) |property_name| {
        if (self.core.accept(RuleSet.is(.@":"))) |_| {
            const binding_element = try self.acceptBindingElement();
            return .{
                .property_name_and_binding_element = .{
                    .property_name = property_name,
                    .binding_element = binding_element,
                },
            };
        } else |_| if (property_name == .literal_property_name and property_name.literal_property_name == .identifier) {
            const ctx: AcceptContext = .{ .precedence = getPrecedence(.@",") + 1 };
            const initializer = if (self.core.accept(RuleSet.is(.@"="))) |_|
                try self.acceptExpression(ctx)
            else |_|
                null;
            return .{
                .single_name_binding = .{
                    .binding_identifier = property_name.literal_property_name.identifier,
                    .initializer = initializer,
                },
            };
        } else return error.UnexpectedToken;
    } else |_| if (self.acceptSingleNameBinding()) |single_name_binding|
        return .{ .single_name_binding = single_name_binding }
    else |_|
        return error.UnexpectedToken;
}

pub fn acceptBindingElement(self: *Parser) AcceptError!ast.BindingElement {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    if (self.acceptSingleNameBinding()) |single_name_binding|
        return .{ .single_name_binding = single_name_binding }
    else |_| if (self.acceptBindingPattern()) |binding_pattern| {
        const ctx: AcceptContext = .{ .precedence = getPrecedence(.@",") + 1 };
        const initializer = if (self.core.accept(RuleSet.is(.@"="))) |_|
            try self.acceptExpression(ctx)
        else |_|
            null;
        return .{
            .binding_pattern_and_expression = .{
                .binding_pattern = binding_pattern,
                .initializer = initializer,
            },
        };
    } else |_| return error.UnexpectedToken;
}

pub fn acceptSingleNameBinding(self: *Parser) AcceptError!ast.SingleNameBinding {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const binding_identifier = try self.acceptBindingIdentifier();
    const ctx: AcceptContext = .{ .precedence = getPrecedence(.@",") + 1 };
    const initializer = if (self.core.accept(RuleSet.is(.@"="))) |_|
        try self.acceptExpression(ctx)
    else |_|
        null;
    return .{ .binding_identifier = binding_identifier, .initializer = initializer };
}

pub fn acceptBindingRestElement(self: *Parser) AcceptError!ast.BindingRestElement {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    _ = try self.core.accept(RuleSet.is(.@"..."));
    if (self.acceptBindingIdentifier()) |binding_identifier|
        return .{ .binding_identifier = binding_identifier }
    else |_| if (self.acceptBindingPattern()) |binding_pattern|
        return .{ .binding_pattern = binding_pattern }
    else |_|
        return error.UnexpectedToken;
}

pub fn acceptLabelledStatement(self: *Parser) AcceptError!ast.LabelledStatement {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const tmp = temporaryChange(&self.state.in_labelled_statement, true);
    defer tmp.restore();

    const label_identifier = try self.acceptLabelIdentifier(true);
    _ = try self.core.accept(RuleSet.is(.@":"));
    const location = (try self.peekToken()).location;
    const labelled_item: ast.LabelledStatement.LabelledItem = if (self.acceptFunctionDeclaration()) |function_declaration|
        .{ .function_declaration = function_declaration }
    else |_| if (self.acceptStatement()) |statement|
        .{ .statement = statement }
    else |_|
        return error.UnexpectedToken;
    // TODO: Make this dependent on the `enable-annex-b` build flag
    // LabelledItem : FunctionDeclaration
    // - It is a Syntax Error if any source text is matched by this production, unless that source
    //   text is non-strict code and the host is a web browser or otherwise supports Labelled
    //   Function Declarations.
    if (self.state.in_strict_mode and labelled_item == .function_declaration) {
        try self.emitErrorAt(
            location,
            "Labelled function declaration is not permitted in strict mode",
            .{},
        );
        return error.UnexpectedToken;
    }
    return .{ .label_identifier = label_identifier, .labelled_item = labelled_item };
}

pub fn acceptExpressionStatement(self: *Parser) AcceptError!ast.ExpressionStatement {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    var next_token = try self.core.nextToken() orelse return error.EndOfStream;
    switch (next_token.type) {
        // An ExpressionStatement cannot start with a U+007B (LEFT CURLY BRACKET) because that
        // might make it ambiguous with a Block.
        .@"{" => return error.UnexpectedToken,

        // An ExpressionStatement cannot start with the function or class keywords because that
        // would make it ambiguous with a FunctionDeclaration, a GeneratorDeclaration, or a
        // ClassDeclaration.
        .function, .class => return error.UnexpectedToken,

        .identifier => {
            // An ExpressionStatement cannot start with async function because that would make it
            // ambiguous with an AsyncFunctionDeclaration or a AsyncGeneratorDeclaration.
            if (std.mem.eql(u8, next_token.text, "async") and !self.followedByLineTerminator()) {
                next_token = try self.core.nextToken() orelse return error.EndOfStream;
                if (next_token.type == .function) return error.UnexpectedToken;
            }

            // An ExpressionStatement cannot start with the two token sequence let [ because that
            // would make it ambiguous with a let LexicalDeclaration whose first LexicalBinding was
            // an ArrayBindingPattern.
            if (std.mem.eql(u8, next_token.text, "let")) {
                next_token = try self.core.nextToken() orelse return error.EndOfStream;
                if (next_token.type == .@"[") return error.UnexpectedToken;
            }
        },

        else => {},
    }
    self.core.restoreState(state);

    const expression = try self.acceptExpression(.{});
    try self.acceptOrInsertSemicolon();
    return .{ .expression = expression };
}

pub fn acceptIfStatement(self: *Parser) AcceptError!ast.IfStatement {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    _ = try self.core.accept(RuleSet.is(.@"if"));
    _ = try self.core.accept(RuleSet.is(.@"("));
    const test_expression = try self.acceptExpression(.{});
    _ = try self.core.accept(RuleSet.is(.@")"));
    const consequent_statement = if (self.acceptStatement()) |statement|
        statement
    else |_| if (self.acceptIfStatementFunctionDeclaration()) |statement|
        statement
    else |_|
        return error.UnexpectedToken;
    const alternate_statement = if (self.core.accept(RuleSet.is(.@"else"))) |_|
        if (self.acceptStatement()) |statement|
            statement
        else |_| if (self.acceptIfStatementFunctionDeclaration()) |statement|
            statement
        else |_|
            return error.UnexpectedToken
    else |_|
        null;
    return .{
        .test_expression = test_expression,
        .consequent_statement = consequent_statement,
        .alternate_statement = alternate_statement,
    };
}

fn acceptIfStatementFunctionDeclaration(self: *Parser) AcceptError!*ast.Statement {
    // B.3.3 FunctionDeclarations in IfStatement Statement Clauses
    // https://tc39.es/ecma262/#sec-functiondeclarations-in-ifstatement-statement-clauses
    // Source text matched by this production is processed as if each matching occurrence of
    // FunctionDeclaration[?Yield, ?Await, ~Default] was the sole StatementListItem of a
    // BlockStatement occupying that position in the source text.

    // TODO: Make this dependent on the `enable-annex-b` build flag
    if (self.state.in_strict_mode) return error.UnexpectedToken;

    const function_declaration = try self.acceptFunctionDeclaration();

    const declaration = try self.allocator.create(ast.Declaration);
    errdefer self.allocator.destroy(declaration);
    declaration.* = .{
        .hoistable_declaration = .{
            .function_declaration = function_declaration,
        },
    };

    var statement_list_items: std.ArrayList(ast.StatementListItem) = .empty;
    errdefer statement_list_items.deinit(self.allocator);
    try statement_list_items.append(self.allocator, .{ .declaration = declaration });

    const statement = try self.allocator.create(ast.Statement);
    errdefer self.allocator.destroy(statement);
    statement.* = .{
        .block_statement = .{
            .block = .{
                .statement_list = .{
                    .items = try statement_list_items.toOwnedSlice(self.allocator),
                },
            },
        },
    };
    return statement;
}

pub fn acceptIterationStatement(self: *Parser) AcceptError!ast.IterationStatement {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const tmp = temporaryChange(&self.state.in_iteration_statement, true);
    defer tmp.restore();

    const error_count = self.diagnostics.errors.items.len;

    return if (self.acceptDoWhileStatement()) |do_while_statement|
        .{ .do_while_statement = do_while_statement }
    else |_| if (self.acceptWhileStatement()) |while_statement|
        .{ .while_statement = while_statement }
    else |_| if (self.acceptForStatement()) |for_statement|
        .{ .for_statement = for_statement }
    else |_| blk: {
        // If parsing the 'for' statement failed we may have emitted a 'let' binding error, e.g.
        // for `for (let let of [])` - get rid of those
        while (self.diagnostics.errors.items.len > error_count) _ = self.diagnostics.errors.pop();
        break :blk if (self.acceptForInOfStatement()) |for_in_of_statement|
            .{ .for_in_of_statement = for_in_of_statement }
        else |_|
            error.UnexpectedToken;
    };
}

pub fn acceptDoWhileStatement(self: *Parser) AcceptError!ast.DoWhileStatement {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    _ = try self.core.accept(RuleSet.is(.do));
    const consequent_statement = try self.acceptStatement();
    _ = try self.core.accept(RuleSet.is(.@"while"));
    _ = try self.core.accept(RuleSet.is(.@"("));
    const test_expression = try self.acceptExpression(.{});
    _ = try self.core.accept(RuleSet.is(.@")"));
    return .{
        .test_expression = test_expression,
        .consequent_statement = consequent_statement,
    };
}

pub fn acceptWhileStatement(self: *Parser) AcceptError!ast.WhileStatement {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    _ = try self.core.accept(RuleSet.is(.@"while"));
    _ = try self.core.accept(RuleSet.is(.@"("));
    const test_expression = try self.acceptExpression(.{});
    _ = try self.core.accept(RuleSet.is(.@")"));
    const consequent_statement = try self.acceptStatement();
    return .{
        .test_expression = test_expression,
        .consequent_statement = consequent_statement,
    };
}

pub fn acceptForStatement(self: *Parser) AcceptError!ast.ForStatement {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const error_count = self.diagnostics.errors.items.len;

    _ = try self.core.accept(RuleSet.is(.@"for"));
    _ = try self.core.accept(RuleSet.is(.@"("));
    const initializer: ?ast.ForStatement.Initializer = if (self.acceptVariableStatement(true)) |variable_statement|
        .{ .variable_statement = variable_statement }
    else |_| if (self.acceptLexicalDeclaration(true)) |lexical_declaration|
        .{ .lexical_declaration = lexical_declaration }
    else |_| blk: {
        // If parsing the lexical declaration failed we may have emitted a 'Missing initializer'
        // diagnostic - get rid of those
        while (self.diagnostics.errors.items.len > error_count) _ = self.diagnostics.errors.pop();
        break :blk if (self.acceptExpression(.{ .forbidden = &.{.in} })) |expression|
            .{ .expression = expression }
        else |_|
            null;
    };
    _ = try self.core.accept(RuleSet.is(.@";"));
    const test_expression = self.acceptExpression(.{}) catch null;
    _ = try self.core.accept(RuleSet.is(.@";"));
    const increment_expression = self.acceptExpression(.{}) catch null;
    _ = try self.core.accept(RuleSet.is(.@")"));
    const consequent_statement = try self.acceptStatement();

    // ForStatement : for ( LexicalDeclaration Expression[opt] ; Expression[opt] ) Statement
    // - It is a Syntax Error if any element of the BoundNames of LexicalDeclaration also occurs
    //   in the VarDeclaredNames of Statement.
    if (initializer) |init| switch (init) {
        .lexical_declaration => |lexical_declaration| {
            var bound_names = IdentifierStackRange.open(self);
            defer bound_names.deinit();
            try lexical_declaration.collectBoundNames(self.allocator, &self.identifier_stack);
            bound_names.close();

            var var_declared_names = IdentifierStackRange.open(self);
            defer var_declared_names.deinit();
            try consequent_statement.collectVarDeclaredNames(self.allocator, &self.identifier_stack);
            var_declared_names.close();

            try self.ensureBoundNamesNotVarDeclared(
                .lexical_declaration,
                bound_names.slice(),
                var_declared_names.slice(),
                state.location,
            );
        },
        else => {},
    };

    return .{
        .initializer = initializer,
        .test_expression = test_expression,
        .increment_expression = increment_expression,
        .consequent_statement = consequent_statement,
    };
}

pub fn acceptForInOfStatement(self: *Parser) AcceptError!ast.ForInOfStatement {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const error_count = self.diagnostics.errors.items.len;

    _ = try self.core.accept(RuleSet.is(.@"for"));
    const maybe_await_token = self.core.accept(RuleSet.is(.await)) catch null;
    _ = try self.core.accept(RuleSet.is(.@"("));
    const initializer_location = (try self.peekToken()).location;
    const initializer: ast.ForInOfStatement.Initializer = if (self.core.accept(RuleSet.is(.@"var"))) |_|
        .{ .for_binding = try self.acceptForBinding() }
    else |_| if (self.acceptForDeclaration()) |for_declaration|
        .{ .for_declaration = for_declaration }
    else |_| blk: {
        // If parsing the for declaration failed we may have emitted a 'Missing initializer'
        // diagnostic - get rid of those
        while (self.diagnostics.errors.items.len > error_count) _ = self.diagnostics.errors.pop();
        break :blk if (self.acceptExpression(.{ .forbidden = &.{.in} })) |expression|
            .{ .expression = expression }
        else |_|
            return error.UnexpectedToken;
    };

    // If LeftHandSideExpression is neither an ObjectLiteral nor an ArrayLiteral, it is a Syntax
    // Error if the AssignmentTargetType of LeftHandSideExpression is invalid.
    if (initializer == .expression and
        initializer.expression != .assignment_pattern and
        initializer.expression.assignmentTargetType(self.state.in_strict_mode) == .invalid)
    {
        try self.emitErrorAt(
            initializer_location,
            "Invalid 'for in'/'for of' loop initializer expression",
            .{},
        );
        return error.UnexpectedToken;
    }

    if (self.state.in_strict_mode and
        initializer == .expression and
        initializer.expression == .primary_expression and
        initializer.expression.primary_expression == .identifier_reference)
    {
        try self.ensureAllowedIdentifier(
            .identifier_reference,
            initializer.expression.primary_expression.identifier_reference,
            initializer_location,
        );
    }

    const @"type": ast.ForInOfStatement.Type = if (self.core.accept(RuleSet.is(.in))) |_| blk: {
        if (maybe_await_token) |await_token| {
            try self.emitErrorAt(await_token.location, "'for in' loop cannot be awaited", .{});
            return error.UnexpectedToken;
        }
        switch (initializer) {
            .for_declaration => |for_decl| switch (for_decl.type) {
                .using, .await_using => {
                    try self.emitErrorAt(
                        initializer_location,
                        "'using' and 'await using' declarations are not allowed in 'for in' loop",
                        .{},
                    );
                    return error.UnexpectedToken;
                },
                else => {},
            },
            else => {},
        }
        break :blk .in;
    } else |_| if (self.acceptKeyword("of")) |_|
        if (maybe_await_token) |_| .async_of else .of
    else |_|
        return error.UnexpectedToken;
    const expression = try self.acceptExpression(.{});
    _ = try self.core.accept(RuleSet.is(.@")"));
    const consequent_statement = try self.acceptStatement();

    // ForInOfStatement :
    //     for ( ForDeclaration in Expression ) Statement
    //     for ( ForDeclaration of AssignmentExpression ) Statement
    //     for await ( ForDeclaration of AssignmentExpression ) Statement
    // - It is a Syntax Error if any element of the BoundNames of ForDeclaration also occurs in the
    //   VarDeclaredNames of Statement.
    if (initializer == .for_declaration) {
        var bound_names = IdentifierStackRange.open(self);
        defer bound_names.deinit();
        try initializer.for_declaration.for_binding.collectBoundNames(self.allocator, &self.identifier_stack);
        bound_names.close();

        var var_declared_names = IdentifierStackRange.open(self);
        defer var_declared_names.deinit();
        try consequent_statement.collectVarDeclaredNames(self.allocator, &self.identifier_stack);
        var_declared_names.close();

        try self.ensureBoundNamesNotVarDeclared(
            .for_declaration,
            bound_names.slice(),
            var_declared_names.slice(),
            initializer_location,
        );
    }

    return .{
        .type = @"type",
        .initializer = initializer,
        .expression = expression,
        .consequent_statement = consequent_statement,
    };
}

pub fn acceptForDeclaration(self: *Parser) AcceptError!ast.ForDeclaration {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const @"type": ast.LexicalDeclaration.Type = if (self.acceptKeyword("let")) |_|
        .let
    else |_| if (self.core.accept(RuleSet.is(.@"const"))) |_|
        .@"const"
    else |_| if (self.acceptKeyword("using")) |_| blk: {
        if (self.followedByLineTerminator()) return error.UnexpectedToken;
        const next = try self.peekToken();
        if (next.type == .identifier and std.mem.eql(u8, next.text, "of")) {
            return error.UnexpectedToken;
        }
        break :blk .using;
    } else |_| if (self.core.accept(RuleSet.is(.await))) |_| blk: {
        if (self.followedByLineTerminator()) return error.UnexpectedToken;
        _ = try self.acceptKeyword("using");
        if (self.followedByLineTerminator()) return error.UnexpectedToken;
        break :blk .await_using;
    } else |_| return error.UnexpectedToken;

    const for_binding = try self.acceptForBinding();

    var bound_names = IdentifierStackRange.open(self);
    defer bound_names.deinit();
    try for_binding.collectBoundNames(self.allocator, &self.identifier_stack);
    bound_names.close();

    // It is a Syntax Error if the BoundNames of ForDeclaration contains "let".
    if (containsSlice(bound_names.slice(), "let")) {
        try self.emitErrorAt(state.location, "For declaration must not have binding named 'let'", .{});
    }

    // It is a Syntax Error if the BoundNames of ForDeclaration contains any duplicate entries.
    try self.ensureUniqueBoundNames(.for_declaration, bound_names.slice(), state.location);

    switch (@"type") {
        .using, .await_using => if (for_binding == .binding_pattern) {
            try self.emitErrorAt(
                state.location,
                "'using' and 'await using' declarations must not contain binding pattern",
                .{},
            );
            return error.UnexpectedToken;
        },
        else => {},
    }

    return .{ .type = @"type", .for_binding = for_binding };
}

pub fn acceptForBinding(self: *Parser) AcceptError!ast.ForBinding {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    if (self.acceptBindingIdentifier()) |binding_identifier|
        return .{ .binding_identifier = binding_identifier }
    else |_| if (self.acceptBindingPattern()) |binding_pattern|
        return .{ .binding_pattern = binding_pattern }
    else |_|
        return error.UnexpectedToken;
}

pub fn acceptContinueStatement(self: *Parser) AcceptError!ast.ContinueStatement {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const token = try self.core.accept(RuleSet.is(.@"continue"));

    if (!self.state.in_iteration_statement) {
        try self.emitErrorAt(
            token.location,
            "'continue' statement is only allowed in iteration statement",
            .{},
        );
        return error.UnexpectedToken;
    }

    if (!self.followedByLineTerminator()) {
        if (self.acceptLabelIdentifier(false)) |label| {
            try self.acceptOrInsertSemicolon();

            if (!self.state.in_labelled_statement) {
                try self.emitErrorAt(
                    token.location,
                    "Labelled 'continue' statement is only allowed in labelled statement",
                    .{},
                );
                return error.UnexpectedToken;
            }

            return .{ .label = label };
        } else |_| {}
    }
    try self.acceptOrInsertSemicolon();
    return .{ .label = null };
}

pub fn acceptBreakStatement(self: *Parser) AcceptError!ast.BreakStatement {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const token = try self.core.accept(RuleSet.is(.@"break"));

    if (!self.followedByLineTerminator()) {
        if (self.acceptLabelIdentifier(false)) |label| {
            try self.acceptOrInsertSemicolon();

            if (!self.state.in_labelled_statement) {
                try self.emitErrorAt(
                    token.location,
                    "Labelled 'break' statement is only allowed in labelled statement",
                    .{},
                );
                return error.UnexpectedToken;
            }

            return .{ .label = label };
        } else |_| {}
    }
    try self.acceptOrInsertSemicolon();

    if (!self.state.in_breakable_statement) {
        try self.emitErrorAt(
            token.location,
            "'break' statement is only allowed in iteration or 'switch' statement",
            .{},
        );
        return error.UnexpectedToken;
    }

    return .{ .label = null };
}

pub fn acceptReturnStatement(self: *Parser) AcceptError!ast.ReturnStatement {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const token = try self.core.accept(RuleSet.is(.@"return"));

    if (!self.state.in_function_body) {
        try self.emitErrorAt(token.location, "'return' statement is only allowed in functions", .{});
        return error.UnexpectedToken;
    }

    if (!self.followedByLineTerminator()) {
        if (self.acceptExpression(.{})) |expression| {
            try self.acceptOrInsertSemicolon();
            return .{ .expression = expression };
        } else |_| {}
    }
    try self.acceptOrInsertSemicolon();
    return .{ .expression = null };
}

pub fn acceptWithStatement(self: *Parser) AcceptError!ast.WithStatement {
    if (!build_options.enable_legacy) return error.UnexpectedToken;

    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const token = try self.core.accept(RuleSet.is(.with));
    if (self.state.in_strict_mode) {
        try self.emitErrorAt(token.location, "'with' statement is not allowed in strict mode", .{});
        return error.UnexpectedToken;
    }
    _ = try self.core.accept(RuleSet.is(.@"("));
    const expression = try self.acceptExpression(.{});
    _ = try self.core.accept(RuleSet.is(.@")"));
    const statement = try self.acceptStatement();
    return .{ .expression = expression, .statement = statement };
}

pub fn acceptSwitchStatement(self: *Parser) AcceptError!ast.SwitchStatement {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    _ = try self.core.accept(RuleSet.is(.@"switch"));
    _ = try self.core.accept(RuleSet.is(.@"("));
    const expression = try self.acceptExpression(.{});
    _ = try self.core.accept(RuleSet.is(.@")"));
    const case_block_location = (try self.peekToken()).location;
    const case_block = try self.acceptCaseBlock();

    var lexically_declared_names = IdentifierStackRange.open(self);
    defer lexically_declared_names.deinit();
    try case_block.collectLexicallyDeclaredNames(self.allocator, &self.identifier_stack);
    lexically_declared_names.close();

    var var_declared_names = IdentifierStackRange.open(self);
    defer var_declared_names.deinit();
    try case_block.collectVarDeclaredNames(self.allocator, &self.identifier_stack);
    var_declared_names.close();

    // - It is a Syntax Error if the LexicallyDeclaredNames of CaseBlock contains any duplicate
    //   entries, unless the host is a web browser or otherwise supports Block-Level Function
    //   Declarations Web Legacy Compatibility Semantics, and both of the following conditions are
    //   true:
    //     - IsStrict(this production) is false.
    //     - The duplicate entries are only bound by FunctionDeclarations.
    // - It is a Syntax Error if any element of the LexicallyDeclaredNames of CaseBlock also occurs
    //   in the VarDeclaredNames of CaseBlock.
    try self.ensureUniqueLexicallyDeclaredNames(
        lexically_declared_names.slice(),
        var_declared_names.slice(),
        case_block_location,
    );

    return .{ .expression = expression, .case_block = case_block };
}

pub fn acceptCaseBlock(self: *Parser) AcceptError!ast.CaseBlock {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    _ = try self.core.accept(RuleSet.is(.@"{"));
    var case_block_items: std.ArrayList(ast.CaseBlock.Item) = .empty;
    errdefer case_block_items.deinit(self.allocator);
    var has_default_clause = false;
    while (self.acceptCaseBlockItem(has_default_clause)) |case_block_item| {
        if (case_block_item == .default_clause) has_default_clause = true;
        try case_block_items.append(self.allocator, case_block_item);
    } else |_| {}
    _ = try self.core.accept(RuleSet.is(.@"}"));
    return .{ .items = try case_block_items.toOwnedSlice(self.allocator) };
}

pub fn acceptCaseBlockItem(self: *Parser, has_default_clause: bool) AcceptError!ast.CaseBlock.Item {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    if (self.acceptCaseClause()) |case_clause|
        return .{ .case_clause = case_clause }
    else |_| if (self.acceptDefaultClause(has_default_clause)) |default_clause|
        return .{ .default_clause = default_clause }
    else |_|
        return error.UnexpectedToken;
}

pub fn acceptCaseClause(self: *Parser) AcceptError!ast.CaseClause {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    _ = try self.core.accept(RuleSet.is(.case));
    const expression = try self.acceptExpression(.{});
    _ = try self.core.accept(RuleSet.is(.@":"));
    const statement_list = try self.acceptStatementList(.{});

    // - It is a Syntax Error if ContainsUsing of StatementList is true.
    if (statement_list.containsUsing()) {
        try self.emitErrorAt(
            state.location,
            "'using' and 'await using' declarations are not allowed in 'case' clause",
            .{},
        );
        return error.UnexpectedToken;
    }

    return .{ .expression = expression, .statement_list = statement_list };
}

pub fn acceptDefaultClause(self: *Parser, has_default_clause: bool) AcceptError!ast.DefaultClause {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const token = try self.core.accept(RuleSet.is(.default));
    if (has_default_clause) {
        try self.emitErrorAt(
            token.location,
            "'switch' statement can only have one 'default' clause",
            .{},
        );
        return error.UnexpectedToken;
    }
    _ = try self.core.accept(RuleSet.is(.@":"));
    const statement_list = try self.acceptStatementList(.{});

    // - It is a Syntax Error if ContainsUsing of StatementList is true.
    if (statement_list.containsUsing()) {
        try self.emitErrorAt(
            state.location,
            "'using' and 'await using' declarations are not allowed in 'default' clause",
            .{},
        );
        return error.UnexpectedToken;
    }

    return .{ .statement_list = statement_list };
}

pub fn acceptThrowStatement(self: *Parser) AcceptError!ast.ThrowStatement {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    _ = try self.core.accept(RuleSet.is(.throw));
    if (self.followedByLineTerminator()) {
        try self.emitErrorAt(self.core.tokenizer.current_location, "Unexpected newline", .{});
    }
    const expression = try self.acceptExpression(.{});
    try self.acceptOrInsertSemicolon();
    return .{ .expression = expression };
}

pub fn acceptTryStatement(self: *Parser) AcceptError!ast.TryStatement {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    _ = try self.core.accept(RuleSet.is(.@"try"));
    const try_block = try self.acceptBlock();
    var catch_parameter: ?ast.CatchParameter = null;
    var catch_parameter_location: Location = undefined;
    const catch_block = if (self.core.accept(RuleSet.is(.@"catch"))) |_| blk: {
        if (self.core.accept(RuleSet.is(.@"("))) |_| {
            catch_parameter_location = (try self.peekToken()).location;
            catch_parameter = try self.acceptCatchParameter();
            _ = try self.core.accept(RuleSet.is(.@")"));
        } else |_| {}
        break :blk try self.acceptBlock();
    } else |_| null;
    const finally_block = if (self.core.accept(RuleSet.is(.finally))) |_|
        try self.acceptBlock()
    else |_|
        null;
    if (catch_block == null and finally_block == null) {
        try self.emitError("'try' statement requires 'catch' or 'finally' block", .{});
        return error.UnexpectedToken;
    }

    if (catch_parameter) |param| {
        var bound_names = IdentifierStackRange.open(self);
        defer bound_names.deinit();
        try param.collectBoundNames(self.allocator, &self.identifier_stack);
        bound_names.close();

        var lexically_declared_names = IdentifierStackRange.open(self);
        defer lexically_declared_names.deinit();
        try catch_block.?.statement_list.collectLexicallyDeclaredNames(self.allocator, &self.identifier_stack);
        lexically_declared_names.close();

        var var_declared_names = IdentifierStackRange.open(self);
        defer var_declared_names.deinit();
        try catch_block.?.statement_list.collectVarDeclaredNames(self.allocator, &self.identifier_stack);
        var_declared_names.close();

        // - It is a Syntax Error if the BoundNames of CatchParameter contains any duplicate
        //   elements.
        // - It is a Syntax Error if any element of the BoundNames of CatchParameter also occurs in
        //   the LexicallyDeclaredNames of Block.
        // - It is a Syntax Error if any element of the BoundNames of CatchParameter also occurs in
        //   the VarDeclaredNames of Block, unless CatchParameter is CatchParameter : BindingIdentifier
        //   and the host is a web browser or otherwise supports VariableStatements in Catch Blocks.
        const allows_var_redeclaration = build_options.enable_annex_b and
            param == .binding_identifier;
        try self.ensureUniqueCatchParameterNames(
            bound_names.slice(),
            lexically_declared_names.slice(),
            var_declared_names.slice(),
            catch_parameter_location,
            allows_var_redeclaration,
        );
    }

    return .{
        .try_block = try_block,
        .catch_parameter = catch_parameter,
        .catch_block = catch_block,
        .finally_block = finally_block,
    };
}

pub fn acceptCatchParameter(self: *Parser) AcceptError!ast.CatchParameter {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    if (self.acceptBindingIdentifier()) |binding_identifier|
        return .{ .binding_identifier = binding_identifier }
    else |_| if (self.acceptBindingPattern()) |binding_pattern|
        return .{ .binding_pattern = binding_pattern }
    else |_|
        return error.UnexpectedToken;
}

pub fn acceptDebuggerStatement(self: *Parser) AcceptError!void {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    _ = try self.core.accept(RuleSet.is(.debugger));
    try self.acceptOrInsertSemicolon();
}

pub fn acceptFormalParameters(self: *Parser) AcceptError!ast.FormalParameters {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const tmp1 = temporaryChange(&self.state.in_formal_parameters, true);
    defer tmp1.restore();

    const tmp2 = temporaryChange(&self.state.arguments_object_needed, false);
    defer tmp2.restore();

    var formal_parameters_items: std.ArrayList(ast.FormalParameters.Item) = .empty;
    errdefer formal_parameters_items.deinit(self.allocator);
    while (true) {
        if (self.acceptBindingRestElement()) |binding_rest_element| {
            const function_rest_parameter: ast.FunctionRestParameter = .{
                .binding_rest_element = binding_rest_element,
            };
            try formal_parameters_items.append(self.allocator, .{ .function_rest_parameter = function_rest_parameter });
            if (self.core.accept(RuleSet.is(.@","))) |token| {
                try self.emitErrorAt(token.location, "Rest parameter must not be followed by comma", .{});
            } else |_| {}
            break;
        } else |_| if (self.acceptBindingElement()) |binding_element| {
            const formal_parameter: ast.FormalParameter = .{
                .binding_element = binding_element,
            };
            try formal_parameters_items.append(self.allocator, .{ .formal_parameter = formal_parameter });
            _ = self.core.accept(RuleSet.is(.@",")) catch break;
        } else |_| break;
    }
    return .{
        .items = try formal_parameters_items.toOwnedSlice(self.allocator),
        .arguments_object_needed = self.state.arguments_object_needed,
    };
}

pub fn acceptFunctionDeclaration(self: *Parser) AcceptError!ast.FunctionDeclaration {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const tmp1 = temporaryChange(&self.state.in_class_static_block, false);
    defer tmp1.restore();

    const tmp2 = temporaryChange(&self.state.in_formal_parameters, false);
    defer tmp2.restore();

    _ = try self.core.accept(RuleSet.is(.function));
    // We need to do this after consuming the 'function' token to skip preceding whitespace.
    const start_offset = self.core.tokenizer.offset - (comptime "function".len);
    const binding_identifier_location = (try self.peekToken()).location;
    const binding_identifier = self.acceptBindingIdentifier() catch |err| blk: {
        if (self.core.peek() catch null) |next_token| if (next_token.type == .@"(") {
            if (self.state.in_default_export) break :blk null;
            try self.emitError("Function declaration must have a binding identifier", .{});
        };
        return err;
    };

    const tmp3 = temporaryChange(&self.state.in_async_function, false);
    defer tmp3.restore();

    const tmp4 = temporaryChange(&self.state.in_generator_function, false);
    defer tmp4.restore();

    const tmp5 = temporaryChange(&self.state.new_target_allowed, true);
    defer tmp5.restore();

    const tmp6 = temporaryChange(&self.state.arguments_disallowed, false);
    defer tmp6.restore();

    const open_parenthesis_token = try self.core.accept(RuleSet.is(.@"("));
    const formal_parameters = try self.acceptFormalParameters();
    _ = try self.core.accept(RuleSet.is(.@")"));
    _ = try self.core.accept(RuleSet.is(.@"{"));
    const function_body = try self.acceptFunctionBody(.normal);
    _ = try self.core.accept(RuleSet.is(.@"}"));
    if (function_body.strict) {
        if (binding_identifier != null) {
            try self.ensureAllowedIdentifier(.binding_identifier, binding_identifier.?, binding_identifier_location);
        }
        try self.ensureUniqueParameterNames(.strict, formal_parameters, open_parenthesis_token.location);
        try self.ensureAllowedParameterNames(formal_parameters, open_parenthesis_token.location);
    } else if (!formal_parameters.isSimpleParameterList()) {
        try self.ensureUniqueParameterNames(.non_simple, formal_parameters, open_parenthesis_token.location);
    }
    if (function_body.functionBodyContainsUseStrict()) {
        try self.ensureSimpleParameterList(formal_parameters, open_parenthesis_token.location);
    }
    const end_offset = self.core.tokenizer.offset;
    const source_range: ast.SourceRange = .{ .start = @intCast(start_offset), .end = @intCast(end_offset) };
    return .{
        .identifier = binding_identifier,
        .formal_parameters = formal_parameters,
        .function_body = function_body,
        .source_range = source_range,
    };
}

pub fn acceptFunctionExpression(self: *Parser) AcceptError!ast.FunctionExpression {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const tmp1 = temporaryChange(&self.state.in_class_static_block, false);
    defer tmp1.restore();

    const tmp2 = temporaryChange(&self.state.in_formal_parameters, false);
    defer tmp2.restore();

    _ = try self.core.accept(RuleSet.is(.function));
    // We need to do this after consuming the 'function' token to skip preceding whitespace.
    const start_offset = self.core.tokenizer.offset - (comptime "function".len);
    const binding_identifier_location = (try self.peekToken()).location;
    const binding_identifier = self.acceptBindingIdentifier() catch null;

    const tmp3 = temporaryChange(&self.state.in_async_function, false);
    defer tmp3.restore();

    const tmp4 = temporaryChange(&self.state.in_generator_function, false);
    defer tmp4.restore();

    const tmp5 = temporaryChange(&self.state.new_target_allowed, true);
    defer tmp5.restore();

    const tmp6 = temporaryChange(&self.state.arguments_disallowed, false);
    defer tmp6.restore();

    const open_parenthesis_token = try self.core.accept(RuleSet.is(.@"("));
    const formal_parameters = try self.acceptFormalParameters();
    _ = try self.core.accept(RuleSet.is(.@")"));
    _ = try self.core.accept(RuleSet.is(.@"{"));
    const function_body = try self.acceptFunctionBody(.normal);
    _ = try self.core.accept(RuleSet.is(.@"}"));
    if (function_body.strict) {
        if (binding_identifier != null) {
            try self.ensureAllowedIdentifier(.binding_identifier, binding_identifier.?, binding_identifier_location);
        }
        try self.ensureUniqueParameterNames(.strict, formal_parameters, open_parenthesis_token.location);
        try self.ensureAllowedParameterNames(formal_parameters, open_parenthesis_token.location);
    } else if (!formal_parameters.isSimpleParameterList()) {
        try self.ensureUniqueParameterNames(.non_simple, formal_parameters, open_parenthesis_token.location);
    }
    if (function_body.functionBodyContainsUseStrict()) {
        try self.ensureSimpleParameterList(formal_parameters, open_parenthesis_token.location);
    }
    const end_offset = self.core.tokenizer.offset;
    const source_range: ast.SourceRange = .{ .start = @intCast(start_offset), .end = @intCast(end_offset) };
    return .{
        .identifier = binding_identifier,
        .formal_parameters = formal_parameters,
        .function_body = function_body,
        .source_range = source_range,
    };
}

pub fn acceptFunctionBody(
    self: *Parser,
    @"type": ast.FunctionBody.Type,
) AcceptError!ast.FunctionBody {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    switch (@"type") {
        .async, .async_generator => std.debug.assert(self.state.in_async_function),
        else => {},
    }
    switch (@"type") {
        .generator, .async_generator => std.debug.assert(self.state.in_generator_function),
        else => {},
    }

    const tmp1 = temporaryChange(&self.state.in_function_body, true);
    defer tmp1.restore();

    const tmp2 = temporaryChange(&self.state.arguments_object_needed, false);
    defer tmp2.restore();

    const statement_list = try self.acceptStatementList(.{ .update_strict_mode = true });

    const strict = self.state.in_strict_mode or statement_list.containsDirective("use strict");
    const function_body: ast.FunctionBody = .{
        .type = @"type",
        .statement_list = statement_list,
        .strict = strict,
        .arguments_object_needed = self.state.arguments_object_needed,
    };

    var lexically_declared_names = IdentifierStackRange.open(self);
    defer lexically_declared_names.deinit();
    try function_body.collectLexicallyDeclaredNames(self.allocator, &self.identifier_stack);
    lexically_declared_names.close();

    var var_declared_names = IdentifierStackRange.open(self);
    defer var_declared_names.deinit();
    try function_body.collectVarDeclaredNames(self.allocator, &self.identifier_stack);
    var_declared_names.close();

    // - It is a Syntax Error if the LexicallyDeclaredNames of FunctionStatementList contains any
    //   duplicate entries.
    // - It is a Syntax Error if any element of the LexicallyDeclaredNames of FunctionStatementList
    //   also occurs in the VarDeclaredNames of FunctionStatementList.
    try self.ensureUniqueLexicallyDeclaredNames(
        lexically_declared_names.slice(),
        var_declared_names.slice(),
        state.location,
    );

    return function_body;
}

pub fn acceptArrowFunction(self: *Parser) AcceptError!ast.ArrowFunction {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const tmp1 = temporaryChange(&self.state.in_class_static_block, false);
    defer tmp1.restore();

    const tmp2 = temporaryChange(&self.state.in_formal_parameters, false);
    defer tmp2.restore();

    var start_offset: usize = undefined;
    const location = (try self.peekToken()).location;
    var formal_parameters: ast.FormalParameters = if (self.acceptBindingIdentifier()) |binding_identifier| blk: {
        // We need to do this after consuming the identifier token to skip preceding whitespace.
        start_offset = self.core.tokenizer.offset - binding_identifier.len;
        var formal_parameters_items = try std.ArrayList(ast.FormalParameters.Item).initCapacity(
            self.allocator,
            1,
        );
        formal_parameters_items.appendAssumeCapacity(.{
            .formal_parameter = .{
                .binding_element = .{
                    .single_name_binding = .{
                        .binding_identifier = binding_identifier,
                        .initializer = null,
                    },
                },
            },
        });
        break :blk .{
            .items = try formal_parameters_items.toOwnedSlice(self.allocator),
            .arguments_object_needed = false,
        };
    } else |_| blk: {
        _ = try self.core.accept(RuleSet.is(.@"("));
        // We need to do this after consuming the '(' token to skip preceding whitespace.
        start_offset = self.core.tokenizer.offset - (comptime "(".len);
        const formal_parameters = try self.acceptFormalParameters();
        _ = try self.core.accept(RuleSet.is(.@")"));
        break :blk formal_parameters;
    };
    if (self.followedByLineTerminator()) {
        try self.emitErrorAt(self.core.tokenizer.current_location, "Unexpected newline", .{});
    }
    _ = try self.core.accept(RuleSet.is(.@"=>"));
    var function_body: ast.FunctionBody = if (self.core.accept(RuleSet.is(.@"{"))) |_| blk: {
        const function_body = try self.acceptFunctionBody(.normal);
        _ = try self.core.accept(RuleSet.is(.@"}"));
        break :blk function_body;
    } else |_| blk: {
        // Mirrors acceptFunctionBody()
        const tmp3 = temporaryChange(&self.state.in_function_body, true);
        defer tmp3.restore();

        const tmp4 = temporaryChange(&self.state.arguments_object_needed, false);
        defer tmp4.restore();

        const ctx: AcceptContext = .{ .precedence = getPrecedence(.@",") + 1 };
        const expression_body = try self.acceptExpression(ctx);
        // Synthesize a FunctionBody with return statement
        const statement = try self.allocator.create(ast.Statement);
        errdefer self.allocator.destroy(statement);
        statement.* = .{ .return_statement = .{ .expression = expression_body } };
        const items = try self.allocator.alloc(ast.StatementListItem, 1);
        errdefer self.allocator.free(items);
        items[0] = .{ .statement = statement };
        const statement_list: ast.StatementList = .{ .items = items };
        break :blk .{
            .type = .normal,
            .statement_list = statement_list,
            .strict = self.state.in_strict_mode,
            .arguments_object_needed = self.state.arguments_object_needed,
        };
    };
    // Even though the arrow function itself never needs an arguments object, it might affect an
    // outer function so we need to propagate that information up.
    self.state.arguments_object_needed =
        self.state.arguments_object_needed or
        formal_parameters.arguments_object_needed or
        function_body.arguments_object_needed;
    formal_parameters.arguments_object_needed = false;
    function_body.arguments_object_needed = false;
    try self.ensureUniqueParameterNames(.arrow, formal_parameters, location);
    if (function_body.strict) {
        try self.ensureAllowedParameterNames(formal_parameters, location);
    }
    if (function_body.functionBodyContainsUseStrict()) {
        try self.ensureSimpleParameterList(formal_parameters, location);
    }
    const end_offset = self.core.tokenizer.offset;
    const source_range: ast.SourceRange = .{ .start = @intCast(start_offset), .end = @intCast(end_offset) };
    return .{
        .formal_parameters = formal_parameters,
        .function_body = function_body,
        .source_range = source_range,
    };
}

pub fn acceptMethodDefinition(
    self: *Parser,
    parsed: ?struct {
        method_type: ast.MethodDefinition.Type,
        start_offset: usize,
    },
) AcceptError!ast.MethodDefinition {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const tmp1 = temporaryChange(&self.state.in_class_static_block, false);
    defer tmp1.restore();

    const tmp2 = temporaryChange(&self.state.in_formal_parameters, false);
    defer tmp2.restore();

    const tmp3 = temporaryChange(&self.state.in_method_definition, true);
    defer tmp3.restore();

    var tmp4: ?TemporaryChange(bool) = null;
    defer if (tmp4) |tmp| tmp.restore();

    const start_offset = if (parsed) |p| p.start_offset else blk: {
        defer self.core.restoreState(state);
        const next_token = (self.core.nextToken() catch null) orelse break :blk 0;
        break :blk self.core.tokenizer.offset - next_token.text.len;
    };

    if (parsed == null) {
        if (self.core.accept(RuleSet.is(.@"*"))) |_|
            return acceptMethodDefinition(self, .{
                .method_type = .generator,
                .start_offset = start_offset,
            })
        else |_| {}
    }

    const class_element_name = try self.acceptClassElementName();
    if (parsed == null and
        class_element_name == .property_name and
        class_element_name.property_name == .literal_property_name and
        class_element_name.property_name.literal_property_name == .identifier)
    {
        const identifier = class_element_name.property_name.literal_property_name.identifier;
        if (self.core.peek() catch null) |next_token| if (next_token.type != .@"(") {
            if (std.mem.eql(u8, identifier, "get")) {
                return acceptMethodDefinition(self, .{
                    .method_type = .get,
                    .start_offset = start_offset,
                });
            }
            if (std.mem.eql(u8, identifier, "set")) {
                return acceptMethodDefinition(self, .{
                    .method_type = .set,
                    .start_offset = start_offset,
                });
            }
            if (std.mem.eql(u8, identifier, "async")) {
                if (self.core.accept(RuleSet.is(.@"*"))) |_|
                    return acceptMethodDefinition(self, .{
                        .method_type = .async_generator,
                        .start_offset = start_offset,
                    })
                else |_| {
                    return acceptMethodDefinition(self, .{
                        .method_type = .async,
                        .start_offset = start_offset,
                    });
                }
            }
        };
        if (self.state.in_class_body and std.mem.eql(u8, identifier, "constructor")) {
            tmp4 = temporaryChange(&self.state.in_class_constructor, true);
        }
    }

    const function_body_type: ast.FunctionBody.Type = switch (if (parsed) |p| p.method_type else .method) {
        .method, .get, .set => .normal,
        .generator => .generator,
        .async => .async,
        .async_generator => .async_generator,
    };
    const tmp5 = temporaryChange(&self.state.in_async_function, switch (function_body_type) {
        .async, .async_generator => true,
        else => false,
    });
    defer tmp5.restore();
    const tmp6 = temporaryChange(&self.state.in_generator_function, switch (function_body_type) {
        .generator, .async_generator => true,
        else => false,
    });
    defer tmp6.restore();

    const tmp7 = temporaryChange(&self.state.new_target_allowed, true);
    defer tmp7.restore();

    const tmp8 = temporaryChange(&self.state.arguments_disallowed, false);
    defer tmp8.restore();

    const open_parenthesis_token = try self.core.accept(RuleSet.is(.@"("));
    const formal_parameters = try self.acceptFormalParameters();
    _ = try self.core.accept(RuleSet.is(.@")"));
    _ = try self.core.accept(RuleSet.is(.@"{"));
    const function_body = try self.acceptFunctionBody(function_body_type);
    _ = try self.core.accept(RuleSet.is(.@"}"));
    try self.ensureUniqueParameterNames(.method, formal_parameters, open_parenthesis_token.location);
    if (function_body.functionBodyContainsUseStrict()) {
        try self.ensureSimpleParameterList(formal_parameters, open_parenthesis_token.location);
    }
    if (parsed) |p| {
        switch (p.method_type) {
            .get => if (formal_parameters.items.len > 0) {
                try self.emitErrorAt(open_parenthesis_token.location, "A 'get' accessor must not have any formal parameters.", .{});
            },
            .set => if (formal_parameters.items.len != 1) {
                try self.emitErrorAt(open_parenthesis_token.location, "A 'set' accessor must have exactly one parameters.", .{});
            },
            else => {},
        }
    }
    const end_offset = self.core.tokenizer.offset;
    const source_range: ast.SourceRange = .{ .start = @intCast(start_offset), .end = @intCast(end_offset) };
    const method = switch (if (parsed) |p| p.method_type else .method) {
        inline else => |@"type"| @unionInit(ast.MethodDefinition.Method, @tagName(@"type"), .{
            .identifier = null,
            .formal_parameters = formal_parameters,
            .function_body = function_body,
            .source_range = source_range,
        }),
    };
    return .{ .class_element_name = class_element_name, .method = method };
}

fn acceptGeneratorDeclaration(self: *Parser) AcceptError!ast.GeneratorDeclaration {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const tmp1 = temporaryChange(&self.state.in_class_static_block, false);
    defer tmp1.restore();

    const tmp2 = temporaryChange(&self.state.in_formal_parameters, false);
    defer tmp2.restore();

    _ = try self.core.accept(RuleSet.is(.function));
    // We need to do this after consuming the 'function' token to skip preceding whitespace.
    const start_offset = self.core.tokenizer.offset - (comptime "function".len);
    _ = try self.core.accept(RuleSet.is(.@"*"));
    const binding_identifier_location = (try self.peekToken()).location;
    const binding_identifier = self.acceptBindingIdentifier() catch |err| blk: {
        if (self.state.in_default_export) break :blk null;
        try self.emitError("Generator declaration must have a binding identifier", .{});
        return err;
    };

    const tmp3 = temporaryChange(&self.state.in_async_function, false);
    defer tmp3.restore();

    const tmp4 = temporaryChange(&self.state.in_generator_function, true);
    defer tmp4.restore();

    const tmp5 = temporaryChange(&self.state.new_target_allowed, true);
    defer tmp5.restore();

    const tmp6 = temporaryChange(&self.state.arguments_disallowed, false);
    defer tmp6.restore();

    const open_parenthesis_token = try self.core.accept(RuleSet.is(.@"("));
    const formal_parameters = try self.acceptFormalParameters();
    _ = try self.core.accept(RuleSet.is(.@")"));
    _ = try self.core.accept(RuleSet.is(.@"{"));
    const function_body = try self.acceptFunctionBody(.generator);
    _ = try self.core.accept(RuleSet.is(.@"}"));
    if (function_body.strict) {
        if (binding_identifier != null) {
            try self.ensureAllowedIdentifier(.binding_identifier, binding_identifier.?, binding_identifier_location);
        }
        try self.ensureUniqueParameterNames(.strict, formal_parameters, open_parenthesis_token.location);
        try self.ensureAllowedParameterNames(formal_parameters, open_parenthesis_token.location);
    } else if (!formal_parameters.isSimpleParameterList()) {
        try self.ensureUniqueParameterNames(.non_simple, formal_parameters, open_parenthesis_token.location);
    }
    if (function_body.functionBodyContainsUseStrict()) {
        try self.ensureSimpleParameterList(formal_parameters, open_parenthesis_token.location);
    }
    const end_offset = self.core.tokenizer.offset;
    const source_range: ast.SourceRange = .{ .start = @intCast(start_offset), .end = @intCast(end_offset) };
    return .{
        .identifier = binding_identifier,
        .formal_parameters = formal_parameters,
        .function_body = function_body,
        .source_range = source_range,
    };
}

pub fn acceptGeneratorExpression(self: *Parser) AcceptError!ast.GeneratorExpression {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const tmp1 = temporaryChange(&self.state.in_class_static_block, false);
    defer tmp1.restore();

    const tmp2 = temporaryChange(&self.state.in_formal_parameters, false);
    defer tmp2.restore();

    _ = try self.core.accept(RuleSet.is(.function));
    // We need to do this after consuming the 'function' token to skip preceding whitespace.
    const start_offset = self.core.tokenizer.offset - (comptime "function".len);
    _ = try self.core.accept(RuleSet.is(.@"*"));
    const binding_identifier_location = (try self.peekToken()).location;
    const binding_identifier = self.acceptBindingIdentifier() catch null;

    const tmp3 = temporaryChange(&self.state.in_async_function, false);
    defer tmp3.restore();

    const tmp4 = temporaryChange(&self.state.in_generator_function, true);
    defer tmp4.restore();

    const tmp5 = temporaryChange(&self.state.new_target_allowed, true);
    defer tmp5.restore();

    const tmp6 = temporaryChange(&self.state.arguments_disallowed, false);
    defer tmp6.restore();

    const open_parenthesis_token = try self.core.accept(RuleSet.is(.@"("));
    const formal_parameters = try self.acceptFormalParameters();
    _ = try self.core.accept(RuleSet.is(.@")"));
    _ = try self.core.accept(RuleSet.is(.@"{"));
    const function_body = try self.acceptFunctionBody(.generator);
    _ = try self.core.accept(RuleSet.is(.@"}"));
    if (function_body.strict) {
        if (binding_identifier != null) {
            try self.ensureAllowedIdentifier(.binding_identifier, binding_identifier.?, binding_identifier_location);
        }
        try self.ensureUniqueParameterNames(.strict, formal_parameters, open_parenthesis_token.location);
        try self.ensureAllowedParameterNames(formal_parameters, open_parenthesis_token.location);
    } else if (!formal_parameters.isSimpleParameterList()) {
        try self.ensureUniqueParameterNames(.non_simple, formal_parameters, open_parenthesis_token.location);
    }
    if (function_body.functionBodyContainsUseStrict()) {
        try self.ensureSimpleParameterList(formal_parameters, open_parenthesis_token.location);
    }
    const end_offset = self.core.tokenizer.offset;
    const source_range: ast.SourceRange = .{ .start = @intCast(start_offset), .end = @intCast(end_offset) };
    return .{
        .identifier = binding_identifier,
        .formal_parameters = formal_parameters,
        .function_body = function_body,
        .source_range = source_range,
    };
}

pub fn acceptYieldExpression(self: *Parser) AcceptError!ast.YieldExpression {
    if (!self.state.in_generator_function) return error.UnexpectedToken;

    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const token = try self.core.accept(RuleSet.is(.yield));

    if (self.state.in_formal_parameters and self.state.in_generator_function) {
        try self.emitErrorAt(
            token.location,
            "Yield expression not allowed in generator formal parameters",
            .{},
        );
    }
    if (!self.followedByLineTerminator()) {
        const ctx: AcceptContext = .{ .precedence = getPrecedence(.yield) + 1 };
        if (self.core.accept(RuleSet.is(.@"*"))) |_| {
            const expr = try self.acceptExpression(ctx);
            const expression = try self.allocator.create(ast.Expression);
            expression.* = expr;
            return .{ .delegate = expression };
        } else |_| if (self.acceptExpression(ctx)) |expr| {
            const expression = try self.allocator.create(ast.Expression);
            expression.* = expr;
            return .{ .expression = expression };
        } else |_| {}
    }
    return .none;
}

fn acceptAsyncGeneratorDeclaration(self: *Parser) AcceptError!ast.AsyncGeneratorDeclaration {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const tmp1 = temporaryChange(&self.state.in_class_static_block, false);
    defer tmp1.restore();

    const tmp2 = temporaryChange(&self.state.in_formal_parameters, false);
    defer tmp2.restore();

    _ = try self.acceptKeyword("async");
    // We need to do this after consuming the 'async' token to skip preceding whitespace.
    const start_offset = self.core.tokenizer.offset - (comptime "async".len);
    if (self.followedByLineTerminator()) {
        try self.emitErrorAt(self.core.tokenizer.current_location, "Unexpected newline", .{});
    }
    _ = try self.core.accept(RuleSet.is(.function));
    _ = try self.core.accept(RuleSet.is(.@"*"));
    const binding_identifier_location = (try self.peekToken()).location;
    const binding_identifier = self.acceptBindingIdentifier() catch |err| blk: {
        if (self.state.in_default_export) break :blk null;
        try self.emitError("Async generator declaration must have a binding identifier", .{});
        return err;
    };

    const tmp3 = temporaryChange(&self.state.in_async_function, true);
    defer tmp3.restore();

    const tmp4 = temporaryChange(&self.state.in_generator_function, true);
    defer tmp4.restore();

    const tmp5 = temporaryChange(&self.state.new_target_allowed, true);
    defer tmp5.restore();

    const tmp6 = temporaryChange(&self.state.arguments_disallowed, false);
    defer tmp6.restore();

    const open_parenthesis_token = try self.core.accept(RuleSet.is(.@"("));
    const formal_parameters = try self.acceptFormalParameters();
    _ = try self.core.accept(RuleSet.is(.@")"));
    _ = try self.core.accept(RuleSet.is(.@"{"));
    const function_body = try self.acceptFunctionBody(.async_generator);
    _ = try self.core.accept(RuleSet.is(.@"}"));
    if (function_body.strict) {
        if (binding_identifier != null) {
            try self.ensureAllowedIdentifier(.binding_identifier, binding_identifier.?, binding_identifier_location);
        }
        try self.ensureUniqueParameterNames(.strict, formal_parameters, open_parenthesis_token.location);
        try self.ensureAllowedParameterNames(formal_parameters, open_parenthesis_token.location);
    } else if (!formal_parameters.isSimpleParameterList()) {
        try self.ensureUniqueParameterNames(.non_simple, formal_parameters, open_parenthesis_token.location);
    }
    if (function_body.functionBodyContainsUseStrict()) {
        try self.ensureSimpleParameterList(formal_parameters, open_parenthesis_token.location);
    }
    const end_offset = self.core.tokenizer.offset;
    const source_range: ast.SourceRange = .{ .start = @intCast(start_offset), .end = @intCast(end_offset) };
    return .{
        .identifier = binding_identifier,
        .formal_parameters = formal_parameters,
        .function_body = function_body,
        .source_range = source_range,
    };
}

pub fn acceptAsyncGeneratorExpression(self: *Parser) AcceptError!ast.AsyncGeneratorExpression {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const tmp1 = temporaryChange(&self.state.in_class_static_block, false);
    defer tmp1.restore();

    const tmp2 = temporaryChange(&self.state.in_formal_parameters, false);
    defer tmp2.restore();

    _ = try self.acceptKeyword("async");
    // We need to do this after consuming the 'async' token to skip preceding whitespace.
    const start_offset = self.core.tokenizer.offset - (comptime "async".len);
    if (self.followedByLineTerminator()) {
        try self.emitErrorAt(self.core.tokenizer.current_location, "Unexpected newline", .{});
    }
    _ = try self.core.accept(RuleSet.is(.function));
    _ = try self.core.accept(RuleSet.is(.@"*"));
    const binding_identifier_location = (try self.peekToken()).location;
    const binding_identifier = self.acceptBindingIdentifier() catch null;

    const tmp3 = temporaryChange(&self.state.in_async_function, true);
    defer tmp3.restore();

    const tmp4 = temporaryChange(&self.state.in_generator_function, true);
    defer tmp4.restore();

    const tmp5 = temporaryChange(&self.state.new_target_allowed, true);
    defer tmp5.restore();

    const tmp6 = temporaryChange(&self.state.arguments_disallowed, false);
    defer tmp6.restore();

    const open_parenthesis_token = try self.core.accept(RuleSet.is(.@"("));
    const formal_parameters = try self.acceptFormalParameters();
    _ = try self.core.accept(RuleSet.is(.@")"));
    _ = try self.core.accept(RuleSet.is(.@"{"));
    const function_body = try self.acceptFunctionBody(.async_generator);
    _ = try self.core.accept(RuleSet.is(.@"}"));
    if (function_body.strict) {
        if (binding_identifier != null) {
            try self.ensureAllowedIdentifier(.binding_identifier, binding_identifier.?, binding_identifier_location);
        }
        try self.ensureUniqueParameterNames(.strict, formal_parameters, open_parenthesis_token.location);
        try self.ensureAllowedParameterNames(formal_parameters, open_parenthesis_token.location);
    } else if (!formal_parameters.isSimpleParameterList()) {
        try self.ensureUniqueParameterNames(.non_simple, formal_parameters, open_parenthesis_token.location);
    }
    if (function_body.functionBodyContainsUseStrict()) {
        try self.ensureSimpleParameterList(formal_parameters, open_parenthesis_token.location);
    }
    const end_offset = self.core.tokenizer.offset;
    const source_range: ast.SourceRange = .{ .start = @intCast(start_offset), .end = @intCast(end_offset) };
    return .{
        .identifier = binding_identifier,
        .formal_parameters = formal_parameters,
        .function_body = function_body,
        .source_range = source_range,
    };
}

fn acceptClassDeclaration(self: *Parser) AcceptError!ast.ClassDeclaration {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    // "All parts of a ClassDeclaration or a ClassExpression are strict mode code."
    const tmp2 = temporaryChange(&self.state.in_strict_mode, true);
    defer tmp2.restore();

    _ = try self.core.accept(RuleSet.is(.class));
    // We need to do this after consuming the 'class' token to skip preceding whitespace.
    const start_offset = self.core.tokenizer.offset - (comptime "class".len);
    const binding_identifier_location = (try self.peekToken()).location;
    const binding_identifier = self.acceptBindingIdentifier() catch |err| blk: {
        if (self.state.in_default_export) break :blk null;
        try self.emitError("Class declaration must have a binding identifier", .{});
        return err;
    };
    if (binding_identifier != null) {
        try self.ensureAllowedIdentifier(.binding_identifier, binding_identifier.?, binding_identifier_location);
    }
    const class_tail = try self.acceptClassTail();
    const end_offset = self.core.tokenizer.offset;
    const source_range: ast.SourceRange = .{ .start = @intCast(start_offset), .end = @intCast(end_offset) };
    return .{
        .identifier = binding_identifier,
        .class_tail = class_tail,
        .source_range = source_range,
    };
}

fn acceptClassExpression(self: *Parser) AcceptError!ast.ClassExpression {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    // "All parts of a ClassDeclaration or a ClassExpression are strict mode code."
    const tmp2 = temporaryChange(&self.state.in_strict_mode, true);
    defer tmp2.restore();

    _ = try self.core.accept(RuleSet.is(.class));
    // We need to do this after consuming the 'class' token to skip preceding whitespace.
    const start_offset = self.core.tokenizer.offset - (comptime "class".len);
    const binding_identifier_location = (try self.peekToken()).location;
    const binding_identifier = self.acceptBindingIdentifier() catch null;
    if (binding_identifier != null) {
        try self.ensureAllowedIdentifier(.binding_identifier, binding_identifier.?, binding_identifier_location);
    }
    const class_tail = try self.acceptClassTail();
    const end_offset = self.core.tokenizer.offset;
    const source_range: ast.SourceRange = .{ .start = @intCast(start_offset), .end = @intCast(end_offset) };
    return .{
        .identifier = binding_identifier,
        .class_tail = class_tail,
        .source_range = source_range,
    };
}

fn acceptClassTail(self: *Parser) AcceptError!ast.ClassTail {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const class_heritage = if (self.core.accept(RuleSet.is(.extends))) |_| blk: {
        const expression = try self.allocator.create(ast.Expression);
        errdefer self.allocator.destroy(expression);
        expression.* = try self.acceptExpression(.{});
        break :blk expression;
    } else |_| null;
    const token = try self.core.accept(RuleSet.is(.@"{"));
    const class_body = try self.acceptClassBody();
    _ = try self.core.accept(RuleSet.is(.@"}"));

    // - It is a Syntax Error if the PrototypePropertyNameList of ClassElementList contains more
    //   than one occurrence of "constructor".
    try self.ensureUniqueConstructorMethod(class_body, token.location);

    // - It is a Syntax Error if the PrivateBoundIdentifiers of ClassElementList contains any
    //   duplicate entries, unless the name is used once for a getter and once for a setter and in
    //   no other entries, and the getter and setter are either both static or both non-static.
    try self.ensureUniquePrivateClassElementNames(class_body, token.location);

    return .{ .class_heritage = class_heritage, .class_body = class_body };
}

fn acceptClassBody(self: *Parser) AcceptError!ast.ClassBody {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const tmp = temporaryChange(&self.state.in_class_body, true);
    defer tmp.restore();

    const class_element_list = try self.acceptClassElementList();
    return .{ .class_element_list = class_element_list };
}

fn acceptClassElementList(self: *Parser) AcceptError!ast.ClassElementList {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    var class_elements: std.ArrayList(ast.ClassElement) = .empty;
    errdefer class_elements.deinit(self.allocator);
    while (self.acceptClassElement()) |class_element|
        try class_elements.append(self.allocator, class_element)
    else |_| {}
    return .{ .items = try class_elements.toOwnedSlice(self.allocator) };
}

fn acceptClassElement(self: *Parser) AcceptError!ast.ClassElement {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    if (self.acceptKeyword("static")) |_| {
        if (self.acceptMethodDefinition(null)) |*method_definition| {
            // It is a Syntax Error if the PropName of MethodDefinition is "prototype".
            if (try method_definition.class_element_name.eql(self.allocator, "prototype")) {
                try self.emitErrorAt(
                    state.location,
                    "Class must not have static method named 'prototype'",
                    .{},
                );
            }
            return .{ .static_method_definition = method_definition.* };
        } else |_| if (self.acceptFieldDefinition()) |field_definition| {
            // It is a Syntax Error if the PropName of FieldDefinition is either "prototype" or
            // "constructor".
            if (try field_definition.class_element_name.eql(self.allocator, "prototype")) {
                try self.emitErrorAt(
                    state.location,
                    "Class must not have static field named 'prototype'",
                    .{},
                );
            } else if (try field_definition.class_element_name.eql(self.allocator, "constructor")) {
                try self.emitErrorAt(
                    state.location,
                    "Class must not have static field named 'constructor'",
                    .{},
                );
            }
            _ = try self.acceptOrInsertSemicolon();
            return .{ .static_field_definition = field_definition };
        } else |_| if (self.acceptClassStaticBlock()) |class_static_block| {
            return .{ .class_static_block = class_static_block };
        } else |_| return error.UnexpectedToken;
    } else |_| if (self.acceptMethodDefinition(null)) |*method_definition| {
        // It is a Syntax Error if the PropName of MethodDefinition is "constructor" and
        // SpecialMethod of MethodDefinition is true.
        if (try method_definition.class_element_name.eql(self.allocator, "constructor") and
            method_definition.specialMethod())
        {
            try self.emitErrorAt(
                state.location,
                "Class constructor must not be an accessor, generator, or async method",
                .{},
            );
        }
        return .{ .method_definition = method_definition.* };
    } else |_| if (self.acceptFieldDefinition()) |field_definition| {
        // It is a Syntax Error if the PropName of FieldDefinition is "constructor".
        if (try field_definition.class_element_name.eql(self.allocator, "constructor")) {
            try self.emitErrorAt(
                state.location,
                "Class must not have field named 'constructor'",
                .{},
            );
        }
        _ = try self.acceptOrInsertSemicolon();
        return .{ .field_definition = field_definition };
    } else |_| if (self.core.accept(RuleSet.is(.@";"))) |_| {
        return .empty_statement;
    } else |_| return error.UnexpectedToken;
}

fn acceptFieldDefinition(self: *Parser) AcceptError!ast.FieldDefinition {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const class_element_name = try self.acceptClassElementName();
    const initializer = if (self.core.accept(RuleSet.is(.@"="))) |_| blk: {
        const tmp = temporaryChange(&self.state.arguments_disallowed, true);
        defer tmp.restore();
        break :blk try self.acceptExpression(.{});
    } else |_| null;
    return .{ .class_element_name = class_element_name, .initializer = initializer };
}

fn acceptClassElementName(self: *Parser) AcceptError!ast.ClassElementName {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const location = (try self.peekToken()).location;
    if (self.acceptPropertyName()) |property_name| {
        return .{ .property_name = property_name };
    } else |_| if (self.acceptPrivateIdentifier()) |private_identifier| {
        // It is a Syntax Error if the StringValue of PrivateIdentifier is "#constructor".
        if (std.mem.eql(u8, private_identifier, "constructor")) {
            try self.emitErrorAt(
                location,
                "Class must not have private element named '#constructor'",
                .{},
            );
        }
        return .{ .private_identifier = private_identifier };
    } else |_| return error.UnexpectedToken;
}

fn acceptClassStaticBlock(self: *Parser) AcceptError!ast.ClassStaticBlock {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const saved_state = self.state;
    defer self.state = saved_state;

    self.state.in_class_static_block = true;
    self.state.in_async_function = false;
    self.state.in_generator_function = false;
    self.state.in_function_body = false;
    self.state.in_breakable_statement = false;
    self.state.in_iteration_statement = false;
    self.state.in_labelled_statement = false;
    self.state.in_class_constructor = false;
    self.state.new_target_allowed = true;
    self.state.arguments_disallowed = true;

    const token = try self.core.accept(RuleSet.is(.@"{"));
    const statement_list = try self.acceptStatementList(.{});
    const class_static_block: ast.ClassStaticBlock = .{ .statement_list = statement_list };
    _ = try self.core.accept(RuleSet.is(.@"}"));

    var lexically_declared_names = IdentifierStackRange.open(self);
    defer lexically_declared_names.deinit();
    try class_static_block.collectLexicallyDeclaredNames(self.allocator, &self.identifier_stack);
    lexically_declared_names.close();

    var var_declared_names = IdentifierStackRange.open(self);
    defer var_declared_names.deinit();
    try class_static_block.collectVarDeclaredNames(self.allocator, &self.identifier_stack);
    var_declared_names.close();

    // - It is a Syntax Error if the LexicallyDeclaredNames of ClassStaticBlockStatementList
    //   contains any duplicate entries.
    // - It is a Syntax Error if any element of the LexicallyDeclaredNames of
    //   ClassStaticBlockStatementList also occurs in the VarDeclaredNames of
    //   ClassStaticBlockStatementList.
    try self.ensureUniqueLexicallyDeclaredNames(
        lexically_declared_names.slice(),
        var_declared_names.slice(),
        token.location,
    );

    return class_static_block;
}

fn acceptRegularExpressionLiteral(self: *Parser) AcceptError!ast.RegularExpressionLiteral {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const token = try self.core.accept(RuleSet.is(.regular_expression));
    const literal = NewTokenizer.RegExpLiteral.parse(token.text).?;
    const pattern = literal.pattern();
    const flags = literal.flags();
    const regular_expression_literal: ast.RegularExpressionLiteral = .{
        .pattern = try self.allocator.dupe(u8, pattern),
        .flags = try self.allocator.dupe(u8, flags),
    };
    switch (try regular_expression_literal.isValidRegularExpressionLiteral(self.allocator)) {
        .invalid_pattern => |str| {
            try self.emitErrorAt(token.location, "Invalid RegExp pattern: {s}", .{str});
            return error.UnexpectedToken;
        },
        .invalid_flags => {
            var flags_location = token.location;
            flags_location.offset = @fromBackingInt(@backingInt(flags_location.offset) + @as(u32, @intCast(pattern.len + 2)));
            try self.emitErrorAt(flags_location, "Invalid RegExp flags '{s}'", .{flags});
            return error.UnexpectedToken;
        },
        .valid => {},
    }
    return regular_expression_literal;
}

fn acceptTemplateLiteral(self: *Parser, tagged: bool) AcceptError!ast.TemplateLiteral {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    var spans: std.ArrayList(ast.TemplateLiteral.Span) = .empty;
    errdefer spans.deinit(self.allocator);
    if (self.core.accept(RuleSet.is(.template))) |template| {
        try spans.append(self.allocator, .{ .template = .{
            .text = try self.allocator.dupe(u8, template.text),
        } });
    } else |_| if (self.core.accept(RuleSet.is(.template_head))) |template_head| {
        try spans.append(self.allocator, .{ .template = .{
            .text = try self.allocator.dupe(u8, template_head.text),
        } });
        while (true) {
            const expression = try self.acceptExpression(.{});
            try spans.append(self.allocator, .{ .expression = expression });
            if (self.core.accept(RuleSet.is(.template_middle))) |template_middle| {
                try spans.append(self.allocator, .{ .template = .{
                    .text = try self.allocator.dupe(u8, template_middle.text),
                } });
            } else |_| break;
        }
        const template_tail = try self.core.accept(RuleSet.is(.template_tail));
        try spans.append(self.allocator, .{ .template = .{
            .text = try self.allocator.dupe(u8, template_tail.text),
        } });
    } else |_| return error.UnexpectedToken;

    if (!tagged) for (spans.items) |span| switch (span) {
        .template => |template| if (!template.validate()) {
            try self.emitErrorAt(state.location, "Invalid escape sequence", .{});
            return error.UnexpectedToken;
        },
        .expression => {},
    };

    return .{ .spans = try spans.toOwnedSlice(self.allocator) };
}

fn acceptAsyncFunctionDeclaration(self: *Parser) AcceptError!ast.AsyncFunctionDeclaration {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const tmp1 = temporaryChange(&self.state.in_class_static_block, false);
    defer tmp1.restore();

    const tmp2 = temporaryChange(&self.state.in_formal_parameters, false);
    defer tmp2.restore();

    _ = try self.acceptKeyword("async");
    // We need to do this after consuming the 'async' token to skip preceding whitespace.
    const start_offset = self.core.tokenizer.offset - (comptime "async".len);
    if (self.followedByLineTerminator()) {
        try self.emitErrorAt(self.core.tokenizer.current_location, "Unexpected newline", .{});
    }
    _ = try self.core.accept(RuleSet.is(.function));
    const binding_identifier_location = (try self.peekToken()).location;
    const binding_identifier = self.acceptBindingIdentifier() catch |err| blk: {
        if (self.core.peek() catch null) |next_token| if (next_token.type == .@"(") {
            if (self.state.in_default_export) break :blk null;
            try self.emitError("Async function declaration must have a binding identifier", .{});
        };
        return err;
    };

    const tmp3 = temporaryChange(&self.state.in_async_function, true);
    defer tmp3.restore();

    const tmp4 = temporaryChange(&self.state.in_generator_function, false);
    defer tmp4.restore();

    const tmp5 = temporaryChange(&self.state.new_target_allowed, true);
    defer tmp5.restore();

    const tmp6 = temporaryChange(&self.state.arguments_disallowed, false);
    defer tmp6.restore();

    const open_parenthesis_token = try self.core.accept(RuleSet.is(.@"("));
    const formal_parameters = try self.acceptFormalParameters();
    _ = try self.core.accept(RuleSet.is(.@")"));
    _ = try self.core.accept(RuleSet.is(.@"{"));
    const function_body = try self.acceptFunctionBody(.async);
    _ = try self.core.accept(RuleSet.is(.@"}"));
    if (function_body.strict) {
        if (binding_identifier != null) {
            try self.ensureAllowedIdentifier(.binding_identifier, binding_identifier.?, binding_identifier_location);
        }
        try self.ensureUniqueParameterNames(.strict, formal_parameters, open_parenthesis_token.location);
        try self.ensureAllowedParameterNames(formal_parameters, open_parenthesis_token.location);
    } else if (!formal_parameters.isSimpleParameterList()) {
        try self.ensureUniqueParameterNames(.non_simple, formal_parameters, open_parenthesis_token.location);
    }
    if (function_body.functionBodyContainsUseStrict()) {
        try self.ensureSimpleParameterList(formal_parameters, open_parenthesis_token.location);
    }
    const end_offset = self.core.tokenizer.offset;
    const source_range: ast.SourceRange = .{ .start = @intCast(start_offset), .end = @intCast(end_offset) };
    return .{
        .identifier = binding_identifier,
        .formal_parameters = formal_parameters,
        .function_body = function_body,
        .source_range = source_range,
    };
}

pub fn acceptAsyncFunctionExpression(self: *Parser) AcceptError!ast.AsyncFunctionExpression {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const tmp1 = temporaryChange(&self.state.in_class_static_block, false);
    defer tmp1.restore();

    const tmp2 = temporaryChange(&self.state.in_formal_parameters, false);
    defer tmp2.restore();

    _ = try self.acceptKeyword("async");
    // We need to do this after consuming the 'async' token to skip preceding whitespace.
    const start_offset = self.core.tokenizer.offset - (comptime "async".len);
    if (self.followedByLineTerminator()) {
        try self.emitErrorAt(self.core.tokenizer.current_location, "Unexpected newline", .{});
    }
    _ = try self.core.accept(RuleSet.is(.function));
    const binding_identifier_location = (try self.peekToken()).location;
    const binding_identifier = self.acceptBindingIdentifier() catch null;

    const tmp3 = temporaryChange(&self.state.in_async_function, true);
    defer tmp3.restore();

    const tmp4 = temporaryChange(&self.state.in_generator_function, false);
    defer tmp4.restore();

    const tmp5 = temporaryChange(&self.state.new_target_allowed, true);
    defer tmp5.restore();

    const tmp6 = temporaryChange(&self.state.arguments_disallowed, false);
    defer tmp6.restore();

    const open_parenthesis_token = try self.core.accept(RuleSet.is(.@"("));
    const formal_parameters = try self.acceptFormalParameters();
    _ = try self.core.accept(RuleSet.is(.@")"));
    _ = try self.core.accept(RuleSet.is(.@"{"));
    const function_body = try self.acceptFunctionBody(.async);
    _ = try self.core.accept(RuleSet.is(.@"}"));
    if (function_body.strict) {
        if (binding_identifier != null) {
            try self.ensureAllowedIdentifier(.binding_identifier, binding_identifier.?, binding_identifier_location);
        }
        try self.ensureUniqueParameterNames(.strict, formal_parameters, open_parenthesis_token.location);
        try self.ensureAllowedParameterNames(formal_parameters, open_parenthesis_token.location);
    } else if (!formal_parameters.isSimpleParameterList()) {
        try self.ensureUniqueParameterNames(.non_simple, formal_parameters, open_parenthesis_token.location);
    }
    if (function_body.functionBodyContainsUseStrict()) {
        try self.ensureSimpleParameterList(formal_parameters, open_parenthesis_token.location);
    }
    const end_offset = self.core.tokenizer.offset;
    const source_range: ast.SourceRange = .{ .start = @intCast(start_offset), .end = @intCast(end_offset) };
    return .{
        .identifier = binding_identifier,
        .formal_parameters = formal_parameters,
        .function_body = function_body,
        .source_range = source_range,
    };
}

pub fn acceptAwaitExpression(self: *Parser) AcceptError!ast.AwaitExpression {
    if (!(self.state.in_async_function or
        (self.state.in_module and !self.state.in_function_body)))
    {
        return error.UnexpectedToken;
    }

    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const token = try self.core.accept(RuleSet.is(.await));
    if (self.state.in_formal_parameters and self.state.in_async_function) {
        try self.emitErrorAt(
            token.location,
            "Await expression not allowed in async formal parameters",
            .{},
        );
    }
    const expression = try self.allocator.create(ast.Expression);
    errdefer self.allocator.destroy(expression);
    const ctx: AcceptContext = .{ .precedence = getPrecedence(.await) + 1 };
    expression.* = try self.acceptExpression(ctx);
    return .{ .expression = expression };
}

pub fn acceptAsyncArrowFunction(self: *Parser) AcceptError!ast.AsyncArrowFunction {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const tmp1 = temporaryChange(&self.state.in_class_static_block, false);
    defer tmp1.restore();

    const tmp2 = temporaryChange(&self.state.in_formal_parameters, false);
    defer tmp2.restore();

    const error_count = self.diagnostics.errors.items.len;

    _ = try self.acceptKeyword("async");
    // We need to do this after consuming the 'async' token to skip preceding whitespace.
    const start_offset = self.core.tokenizer.offset - (comptime "async".len);
    if (self.followedByLineTerminator()) {
        try self.emitErrorAt(self.core.tokenizer.current_location, "Unexpected newline", .{});
    }

    const tmp3 = temporaryChange(&self.state.in_async_function, true);
    defer tmp3.restore();

    const tmp4 = temporaryChange(&self.state.in_generator_function, false);
    defer tmp4.restore();

    const location = (try self.peekToken()).location;
    var formal_parameters: ast.FormalParameters = if (self.acceptBindingIdentifier()) |binding_identifier| blk: {
        var formal_parameters_items = try std.ArrayList(ast.FormalParameters.Item).initCapacity(
            self.allocator,
            1,
        );
        formal_parameters_items.appendAssumeCapacity(.{
            .formal_parameter = .{
                .binding_element = .{
                    .single_name_binding = .{
                        .binding_identifier = binding_identifier,
                        .initializer = null,
                    },
                },
            },
        });
        break :blk .{
            .items = try formal_parameters_items.toOwnedSlice(self.allocator),
            .arguments_object_needed = false,
        };
    } else |_| blk: {
        _ = try self.core.accept(RuleSet.is(.@"("));
        const formal_parameters = try self.acceptFormalParameters();
        _ = try self.core.accept(RuleSet.is(.@")"));
        break :blk formal_parameters;
    };
    _ = self.core.accept(RuleSet.is(.@"=>")) catch |err| {
        // If parsing the async arrow function failed we may have emitted an 'invalid binding
        // identifier' error, e.g. for `async (await)` - get rid of those
        while (self.diagnostics.errors.items.len > error_count) _ = self.diagnostics.errors.pop();
        return err;
    };
    if (self.followedByLineTerminator()) {
        try self.emitErrorAt(self.core.tokenizer.current_location, "Unexpected newline", .{});
    }
    var function_body: ast.FunctionBody = if (self.core.accept(RuleSet.is(.@"{"))) |_| blk: {
        const function_body = try self.acceptFunctionBody(.async);
        _ = try self.core.accept(RuleSet.is(.@"}"));
        break :blk function_body;
    } else |_| blk: {
        const tmp5 = temporaryChange(&self.state.in_function_body, true);
        defer tmp5.restore();

        const tmp6 = temporaryChange(&self.state.arguments_object_needed, false);
        defer tmp6.restore();

        const ctx: AcceptContext = .{ .precedence = getPrecedence(.@",") + 1 };
        const expression_body = try self.acceptExpression(ctx);
        // Synthesize a FunctionBody with return statement
        const statement = try self.allocator.create(ast.Statement);
        errdefer self.allocator.destroy(statement);
        statement.* = .{ .return_statement = .{ .expression = expression_body } };
        const items = try self.allocator.alloc(ast.StatementListItem, 1);
        errdefer self.allocator.free(items);
        items[0] = .{ .statement = statement };
        const statement_list: ast.StatementList = .{ .items = items };
        break :blk .{
            .type = .async,
            .statement_list = statement_list,
            .strict = self.state.in_strict_mode,
            .arguments_object_needed = self.state.arguments_object_needed,
        };
    };
    // Even though the arrow function itself never needs an arguments object, it might affect an
    // outer function so we need to propagate that information up.
    self.state.arguments_object_needed =
        self.state.arguments_object_needed or
        formal_parameters.arguments_object_needed or
        function_body.arguments_object_needed;
    formal_parameters.arguments_object_needed = false;
    function_body.arguments_object_needed = false;
    try self.ensureUniqueParameterNames(.arrow, formal_parameters, location);
    if (function_body.strict) {
        try self.ensureAllowedParameterNames(formal_parameters, location);
    }
    if (function_body.functionBodyContainsUseStrict()) {
        try self.ensureSimpleParameterList(formal_parameters, location);
    }
    const end_offset = self.core.tokenizer.offset;
    const source_range: ast.SourceRange = .{ .start = @intCast(start_offset), .end = @intCast(end_offset) };
    return .{
        .formal_parameters = formal_parameters,
        .function_body = function_body,
        .source_range = source_range,
    };
}

pub fn acceptScript(self: *Parser) AcceptError!ast.Script {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const statement_list = try self.acceptStatementList(.{ .update_strict_mode = true });
    const script: ast.Script = .{ .statement_list = statement_list };

    var lexically_declared_names = IdentifierStackRange.open(self);
    defer lexically_declared_names.deinit();
    try script.collectLexicallyDeclaredNames(self.allocator, &self.identifier_stack);
    lexically_declared_names.close();

    var var_declared_names = IdentifierStackRange.open(self);
    defer var_declared_names.deinit();
    try script.collectVarDeclaredNames(self.allocator, &self.identifier_stack);
    var_declared_names.close();

    // - It is a Syntax Error if the LexicallyDeclaredNames of ScriptBody contains any duplicate
    //   entries.
    // - It is a Syntax Error if any element of the LexicallyDeclaredNames of ScriptBody also
    //   occurs in the VarDeclaredNames of ScriptBody.
    try self.ensureUniqueLexicallyDeclaredNames(
        lexically_declared_names.slice(),
        var_declared_names.slice(),
        state.location,
    );

    // - It is a Syntax Error if ContainsUsing of StatementList is true.
    if (statement_list.containsUsing()) {
        try self.emitErrorAt(
            state.location,
            "'using' and 'await using' declarations are not allowed at the top level of a script",
            .{},
        );
        return error.UnexpectedToken;
    }

    return script;
}

pub fn acceptModule(self: *Parser) AcceptError!ast.Module {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const tmp1 = temporaryChange(&self.state.in_module, true);
    defer tmp1.restore();

    // "Module code is always strict mode code."
    const tmp2 = temporaryChange(&self.state.in_strict_mode, true);
    defer tmp2.restore();

    const module_item_list = try self.acceptModuleItemList();
    const module: ast.Module = .{ .module_item_list = module_item_list };

    var lexically_declared_names = IdentifierStackRange.open(self);
    defer lexically_declared_names.deinit();
    try module_item_list.collectLexicallyDeclaredNames(self.allocator, &self.identifier_stack);
    lexically_declared_names.close();

    var var_declared_names = IdentifierStackRange.open(self);
    defer var_declared_names.deinit();
    try module_item_list.collectVarDeclaredNames(self.allocator, &self.identifier_stack);
    var_declared_names.close();

    // - It is a Syntax Error if the LexicallyDeclaredNames of ModuleItemList contains any
    //   duplicate entries.
    // - It is a Syntax Error if any element of the LexicallyDeclaredNames of ModuleItemList also
    //   occurs in the VarDeclaredNames of ModuleItemList.
    try self.ensureUniqueLexicallyDeclaredNames(
        lexically_declared_names.slice(),
        var_declared_names.slice(),
        state.location,
    );

    return module;
}

pub fn acceptModuleItemList(self: *Parser) AcceptError!ast.ModuleItemList {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    var module_items: std.ArrayList(ast.ModuleItem) = .empty;
    errdefer module_items.deinit(self.allocator);
    while (self.acceptModuleItem()) |module_item|
        try module_items.append(self.allocator, module_item)
    else |_| {}
    return .{ .items = try module_items.toOwnedSlice(self.allocator) };
}

pub fn acceptModuleItem(self: *Parser) AcceptError!ast.ModuleItem {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    if (self.acceptImportDeclaration()) |import_declaration|
        return .{ .import_declaration = import_declaration }
    else |_| if (self.acceptExportDeclaration()) |export_declaration|
        return .{ .export_declaration = export_declaration }
    else |_| if (self.acceptStatementListItem()) |statement_list_item|
        return .{ .statement_list_item = statement_list_item }
    else |_|
        return error.UnexpectedToken;
}

pub fn acceptModuleExportName(self: *Parser) AcceptError!ast.ModuleExportName {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    if (self.acceptIdentifierName()) |identifier|
        return .{ .identifier = identifier }
    else |_| if (self.acceptStringLiteral()) |string_literal|
        return .{ .string_literal = string_literal }
    else |_|
        return error.UnexpectedToken;
}

pub fn acceptImportDeclaration(self: *Parser) AcceptError!ast.ImportDeclaration {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    _ = try self.core.accept(RuleSet.is(.import));
    const import_clause = if (self.acceptImportClause()) |import_clause| blk: {
        _ = try self.acceptKeyword("from");
        break :blk import_clause;
    } else |_| null;
    const module_specifier = try self.acceptStringLiteral();
    const with_clause = self.acceptWithClause() catch null;
    _ = try self.acceptOrInsertSemicolon();
    return .{
        .import_clause = import_clause,
        .module_specifier = module_specifier,
        .with_clause = with_clause,
    };
}

pub fn acceptImportClause(self: *Parser) AcceptError!ast.ImportClause {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    if (self.acceptBindingIdentifier()) |imported_default_binding| {
        if (self.core.accept(RuleSet.is(.@","))) |_| {
            if (self.acceptNameSpaceImport()) |namespace_import|
                return .{
                    .imported_default_binding_and_namespace_import = .{
                        .imported_default_binding = imported_default_binding,
                        .namespace_import = namespace_import,
                    },
                }
            else |_| if (self.acceptImportsList()) |named_imports|
                return .{
                    .imported_default_binding_and_named_imports = .{
                        .imported_default_binding = imported_default_binding,
                        .named_imports = named_imports,
                    },
                }
            else |_|
                return error.UnexpectedToken;
        } else |_| {
            return .{ .imported_default_binding = imported_default_binding };
        }
    } else |_| if (self.acceptNameSpaceImport()) |namespace_import|
        return .{ .namespace_import = namespace_import }
    else |_| if (self.acceptImportsList()) |named_imports|
        return .{ .named_imports = named_imports }
    else |_|
        return error.UnexpectedToken;
}

pub fn acceptNameSpaceImport(self: *Parser) AcceptError!ast.Identifier {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    _ = try self.core.accept(RuleSet.is(.@"*"));
    _ = try self.acceptKeyword("as");
    return self.acceptBindingIdentifier();
}

pub fn acceptImportsList(self: *Parser) AcceptError!ast.ImportsList {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    var import_specifiers: std.ArrayList(ast.ImportSpecifier) = .empty;
    errdefer import_specifiers.deinit(self.allocator);
    _ = try self.core.accept(RuleSet.is(.@"{"));
    while (self.acceptImportSpecifier()) |import_specifier| {
        try import_specifiers.append(self.allocator, import_specifier);
        _ = self.core.accept(RuleSet.is(.@",")) catch break;
    } else |_| {}
    _ = try self.core.accept(RuleSet.is(.@"}"));
    return .{ .items = try import_specifiers.toOwnedSlice(self.allocator) };
}

pub fn acceptImportSpecifier(self: *Parser) AcceptError!ast.ImportSpecifier {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const module_export_name = try self.acceptModuleExportName();
    if (self.acceptKeyword("as")) |_|
        return .{
            .module_export_name = module_export_name,
            .imported_binding = try self.acceptBindingIdentifier(),
        }
    else |_| if (module_export_name == .identifier)
        return .{
            .module_export_name = null,
            .imported_binding = module_export_name.identifier,
        }
    else
        return error.UnexpectedToken;
}

pub fn acceptWithClause(self: *Parser) AcceptError!ast.WithClause {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    _ = try self.core.accept(RuleSet.is(.with));
    var with_clause_items: std.ArrayList(ast.WithClause.Item) = .empty;
    errdefer with_clause_items.deinit(self.allocator);
    var seen_keys: String.HashMap(void) = .empty;
    defer seen_keys.deinit(self.allocator);
    _ = try self.core.accept(RuleSet.is(.@"{"));
    while (self.acceptWithClauseItem(&seen_keys)) |with_clause_item| {
        try with_clause_items.append(self.allocator, with_clause_item);
        _ = self.core.accept(RuleSet.is(.@",")) catch break;
    } else |_| {}
    _ = try self.core.accept(RuleSet.is(.@"}"));
    return .{ .items = try with_clause_items.toOwnedSlice(self.allocator) };
}

pub fn acceptWithClauseItem(
    self: *Parser,
    seen_keys: *String.HashMap(void),
) AcceptError!ast.WithClause.Item {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const location = (try self.peekToken()).location;
    const key = try self.acceptAttributeKey();
    const key_string = switch (key) {
        .identifier => |identifier| try String.fromUtf8Alloc(self.allocator, identifier),
        .string_literal => |string_literal| try string_literal.stringValue(self.allocator),
    };
    // It is a Syntax Error if WithClauseToAttributes of WithClause has two different entries a and
    // b such that a.[[Key]] is b.[[Key]].
    const gop = try seen_keys.getOrPut(self.allocator, key_string);
    if (gop.found_existing) {
        try self.emitErrorAt(
            location,
            "Import attribute has duplicate key '{f}'",
            .{key_string.fmtEscaped()},
        );
        return error.UnexpectedToken;
    }
    _ = try self.core.accept(RuleSet.is(.@":"));
    const value = try self.acceptStringLiteral();
    return .{ .key = key, .value = value };
}

pub fn acceptAttributeKey(self: *Parser) AcceptError!ast.AttributeKey {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    if (self.acceptIdentifierName()) |identifier|
        return .{ .identifier = identifier }
    else |_| if (self.acceptStringLiteral()) |string_literal|
        return .{ .string_literal = string_literal }
    else |_|
        return error.UnexpectedToken;
}

pub fn acceptExportDeclaration(self: *Parser) AcceptError!ast.ExportDeclaration {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    _ = try self.core.accept(RuleSet.is(.@"export"));
    const location = (try self.peekToken()).location;
    if (self.acceptExportFrom()) |export_from|
        return .{ .export_from = export_from }
    else |_| if (self.acceptNamedExports()) |named_exports| {
        _ = try self.acceptOrInsertSemicolon();
        return .{ .named_exports = named_exports };
    } else |_| if (self.acceptVariableStatement(false)) |variable_statement|
        return .{ .variable_statement = variable_statement }
    else |_| if (self.acceptDeclaration()) |declaration| {
        // export [lookahead ∉ { using, await }] Declaration
        switch (declaration.*) {
            .lexical_declaration => |lex_decl| switch (lex_decl.type) {
                .using, .await_using => {
                    try self.emitErrorAt(
                        location,
                        "'using' and 'await using' declarations are not allowed in export declaration",
                        .{},
                    );
                    return error.UnexpectedToken;
                },
                else => {},
            },
            else => {},
        }
        return .{ .declaration = declaration };
    } else |_| if (self.core.accept(RuleSet.is(.default))) |_| {
        const tmp = temporaryChange(&self.state.in_default_export, true);
        defer tmp.restore();
        if (self.acceptHoistableDeclaration()) |hoistable_declaration|
            return .{ .default_hoistable_declaration = hoistable_declaration }
        else |_| if (self.acceptClassDeclaration()) |class_declaration|
            return .{ .default_class_declaration = class_declaration }
        else |_| if (self.acceptExpression(.{})) |expression|
            return .{ .default_expression = expression }
        else |_|
            return error.UnexpectedToken;
    } else |_| return error.UnexpectedToken;
}

pub fn acceptExportFrom(self: *Parser) AcceptError!ast.ExportDeclaration.ExportFrom {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const export_from_clause = try self.acceptExportFromClause();
    _ = try self.acceptKeyword("from");
    const module_specifier = try self.acceptStringLiteral();
    const with_clause = self.acceptWithClause() catch null;
    _ = try self.acceptOrInsertSemicolon();
    return .{
        .export_from_clause = export_from_clause,
        .module_specifier = module_specifier,
        .with_clause = with_clause,
    };
}

pub fn acceptExportFromClause(self: *Parser) AcceptError!ast.ExportFromClause {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    if (self.core.accept(RuleSet.is(.@"*"))) |_| {
        if (self.acceptKeyword("as")) |_|
            return .{ .star_as = try self.acceptModuleExportName() }
        else |_|
            return .star;
    } else |_| if (self.acceptNamedExports()) |named_exports|
        return .{ .named_exports = named_exports }
    else |_|
        return error.UnexpectedToken;
}

pub fn acceptNamedExports(self: *Parser) AcceptError!ast.NamedExports {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const exports_list = try self.acceptExportsList();
    return .{ .exports_list = exports_list };
}

pub fn acceptExportsList(self: *Parser) AcceptError!ast.ExportsList {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    _ = try self.core.accept(RuleSet.is(.@"{"));
    var export_specifiers: std.ArrayList(ast.ExportSpecifier) = .empty;
    errdefer export_specifiers.deinit(self.allocator);
    while (self.acceptExportSpecifier()) |export_specifier| {
        try export_specifiers.append(self.allocator, export_specifier);
        _ = self.core.accept(RuleSet.is(.@",")) catch break;
    } else |_| {}
    _ = try self.core.accept(RuleSet.is(.@"}"));
    return .{ .items = try export_specifiers.toOwnedSlice(self.allocator) };
}

pub fn acceptExportSpecifier(self: *Parser) AcceptError!ast.ExportSpecifier {
    const state = self.core.saveState();
    errdefer self.core.restoreState(state);

    const name = try self.acceptModuleExportName();
    const alias = if (self.acceptKeyword("as")) |_|
        try self.acceptModuleExportName()
    else |_|
        null;
    return .{ .name = name, .alias = alias };
}
