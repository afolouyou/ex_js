const std = @import("std");

const libregexp = @import("libregexp");

const build_options = @import("build-options");
const language = @import("../language.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

const BigInt = types.BigInt;
const ImportAttribute = language.ImportAttribute;
const ExportEntry = language.ExportEntry;
const ImportEntry = language.ImportEntry;
const ModuleRequest = language.ModuleRequest;
const String = types.String;
const Tokenizer = language.Tokenizer;
const Value = types.Value;
const containsSlice = utils.containsSlice;

pub const SourceRange = struct {
    /// Byte offset into the UTF-8 source text, inclusive.
    start: u32,
    /// Byte offset into the UTF-8 source text, exclusive.
    end: u32,
};

const AnalyzeQuery = enum {
    is_await_expression,
    is_identifier_reference,
    is_member_expression,
    is_reference,
    is_string_literal,
};

pub const VarScopedDeclaration = union(enum) {
    variable_declaration: VariableDeclaration,
    hoistable_declaration: HoistableDeclaration,
};

pub const LexicallyScopedDeclaration = union(enum) {
    hoistable_declaration: HoistableDeclaration,
    class_declaration: ClassDeclaration,
    lexical_declaration: LexicalDeclaration,
    export_declaration: Expression,

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: LexicallyScopedDeclaration,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        switch (self) {
            // ExportDeclaration : export default AssignmentExpression ;
            .export_declaration => {
                // 1. Return « "*default*" ».
                try bound_names.append(allocator, "*default*");
            },
            inline else => |node| try node.collectBoundNames(allocator, bound_names),
        }
    }

    /// 8.2.3 Static Semantics: IsConstantDeclaration
    /// https://tc39.es/ecma262/#sec-static-semantics-isconstantdeclaration
    pub fn isConstantDeclaration(self: LexicallyScopedDeclaration) bool {
        switch (self) {
            // ExportDeclaration :
            //     export ExportFromClause FromClause WithClause[opt] ;
            //     export NamedExports ;
            //     export default AssignmentExpression ;
            .export_declaration => {
                // 1. Return false.
                return false;
            },
            inline else => |node| return node.isConstantDeclaration(),
        }
    }
};

/// https://tc39.es/ecma262/#prod-IdentifierReference
pub const IdentifierReference = []const u8;

/// https://tc39.es/ecma262/#prod-Identifier
pub const Identifier = []const u8;

/// https://tc39.es/ecma262/#prod-PrivateIdentifier
pub const PrivateIdentifier = []const u8;

/// https://tc39.es/ecma262/#prod-PrimaryExpression
pub const PrimaryExpression = union(enum) {
    this,
    identifier_reference: IdentifierReference,
    literal: Literal,
    array_literal: ArrayLiteral,
    object_literal: ObjectLiteral,
    function_expression: FunctionExpression,
    class_expression: ClassExpression,
    generator_expression: GeneratorExpression,
    async_function_expression: AsyncFunctionExpression,
    async_generator_expression: AsyncGeneratorExpression,
    regular_expression_literal: RegularExpressionLiteral,
    template_literal: TemplateLiteral,
    arrow_function: ArrowFunction,
    async_arrow_function: AsyncArrowFunction,

    pub fn analyze(self: PrimaryExpression, query: AnalyzeQuery) bool {
        return switch (query) {
            .is_await_expression,
            .is_member_expression,
            => false,
            .is_identifier_reference,
            .is_reference,
            => switch (self) {
                .identifier_reference => true,
                else => false,
            },
            .is_string_literal => switch (self) {
                .literal => |literal| literal.analyze(query),
                else => false,
            },
        };
    }
};

/// https://tc39.es/ecma262/#prod-MemberExpression
pub const MemberExpression = struct {
    pub const Property = union(enum) {
        expression: *Expression,
        identifier: Identifier,
        private_identifier: PrivateIdentifier,
    };

    expression: *Expression,
    property: Property,
};

/// https://tc39.es/ecma262/#prod-SuperProperty
pub const SuperProperty = union(enum) {
    expression: *Expression,
    identifier: Identifier,
};

/// https://tc39.es/ecma262/#prod-MetaProperty
pub const MetaProperty = union(enum) {
    new_target,
    import_meta,
};

/// https://tc39.es/ecma262/#prod-NewExpression
pub const NewExpression = struct {
    expression: *Expression,
    arguments: Arguments,
};

/// https://tc39.es/ecma262/#prod-CallExpression
pub const CallExpression = struct {
    expression: *Expression,
    arguments: Arguments,
};

/// https://tc39.es/ecma262/#prod-SuperCall
pub const SuperCall = struct {
    arguments: Arguments,
};

/// https://tc39.es/ecma262/#prod-ImportCall
pub const ImportCall = struct {
    specifier_expression: *Expression,
    options_expression: ?*Expression,
};

/// https://tc39.es/ecma262/#prod-Arguments
pub const Arguments = []const Argument;
pub const Argument = union(enum) {
    expression: Expression,
    spread: Expression,
};

/// https://tc39.es/ecma262/#prod-OptionalExpression
pub const OptionalExpression = struct {
    pub const Property = union(enum) {
        arguments: Arguments,
        expression: *Expression,
        identifier: Identifier,
        private_identifier: PrivateIdentifier,
    };

    expression: *Expression,
    properties: []const Property,
};

/// https://tc39.es/ecma262/#prod-Literal
pub const Literal = union(enum) {
    null,
    boolean: bool,
    numeric: NumericLiteral,
    string: StringLiteral,

    pub fn analyze(self: Literal, query: AnalyzeQuery) bool {
        return switch (query) {
            .is_await_expression,
            .is_identifier_reference,
            .is_member_expression,
            .is_reference,
            => false,
            .is_string_literal => self == .string,
        };
    }
};

/// https://tc39.es/ecma262/#prod-NumericLiteral
pub const NumericLiteral = struct {
    pub const System = Tokenizer.NumericLiteral.Base;

    pub const Production = enum {
        /// Anything else
        regular,
        /// https://tc39.es/ecma262/#prod-LegacyOctalIntegerLiteral
        legacy_octal_integer_literal,
        /// https://tc39.es/ecma262/#prod-NonOctalDecimalIntegerLiteral
        non_octal_decimal_integer_literal,
    };

    pub const Type = Tokenizer.NumericLiteral.Kind;

    text: []const u8,
    system: System,
    production: Production,
    type: Type,

    /// 12.9.3.3 Static Semantics: NumericValue
    /// https://tc39.es/ecma262/#sec-numericvalue
    pub fn numericValue(
        self: NumericLiteral,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!Value {
        const literal: Tokenizer.NumericLiteral = .{
            .text = self.text,
            .kind = self.type,
            .base = self.system,
        };
        switch (self.type) {
            .number => return Value.from(try literal.numberValue(allocator)),
            .big_int => {
                const managed = try literal.bigIntValue(allocator);
                const big_int = try allocator.create(BigInt);
                big_int.* = .{ .managed = managed };
                return Value.from(big_int);
            },
        }
    }
};

/// https://tc39.es/ecma262/#prod-StringLiteral
pub const StringLiteral = struct {
    text: []const u8,

    /// 12.9.4.2 Static Semantics: SV
    /// https://tc39.es/ecma262/#sec-static-semantics-sv
    pub fn stringValue(
        self: StringLiteral,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!*const String {
        std.debug.assert(self.text.len >= 2);
        const literal: Tokenizer.StringLiteral = .{ .text = self.text };
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        const valid = literal.value(&aw.writer) catch return error.OutOfMemory;
        std.debug.assert(valid);
        return String.fromWtf8Alloc(allocator, try aw.toOwnedSlice());
    }
};

/// https://tc39.es/ecma262/#prod-ArrayLiteral
pub const ArrayLiteral = struct {
    pub const Element = union(enum) {
        elision,
        expression: Expression,
        spread: Expression,
    };

    element_list: []const Element,
};

/// https://tc39.es/ecma262/#prod-ObjectLiteral
pub const ObjectLiteral = struct {
    property_definition_list: PropertyDefinitionList,
};

/// https://tc39.es/ecma262/#prod-PropertyDefinitionList
pub const PropertyDefinitionList = struct {
    items: []const PropertyDefinition,

    /// Count the number of properties an object literal will actually define,
    /// i.e. excluding spread and `__proto__` properties.
    ///
    /// Only allocates in the pathological case of an escaped `__proto__` property.
    pub fn propertyCount(
        self: PropertyDefinitionList,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!usize {
        var count: usize = 0;
        for (self.items) |property_definition| switch (property_definition) {
            .spread => {},
            .identifier_reference, .method_definition => count += 1,
            .property_name_and_expression => |p| {
                if (!try p.property_name.eql(allocator, "__proto__")) count += 1;
            },
        };
        return count;
    }
};

/// https://tc39.es/ecma262/#prod-PropertyDefinition
pub const PropertyDefinition = union(enum) {
    pub const PropertyNameAndExpression = struct {
        property_name: PropertyName,
        expression: Expression,
    };

    spread: Expression,
    identifier_reference: IdentifierReference,
    property_name_and_expression: PropertyNameAndExpression,
    method_definition: MethodDefinition,
};

/// https://tc39.es/ecma262/#prod-PropertyName
pub const PropertyName = union(enum) {
    literal_property_name: union(enum) {
        identifier: Identifier,
        string_literal: StringLiteral,
        numeric_literal: NumericLiteral,
    },
    computed_property_name: Expression,

    pub fn eql(
        self: PropertyName,
        allocator: std.mem.Allocator,
        comptime name: []const u8,
    ) std.mem.Allocator.Error!bool {
        switch (self) {
            .literal_property_name => |literal_property_name| switch (literal_property_name) {
                .identifier => |identifier| return std.mem.eql(u8, identifier, name),
                .string_literal => |string_literal| {
                    const string = try string_literal.stringValue(allocator);
                    defer if (string != String.empty) {
                        switch (string.asAsciiOrUtf16()) {
                            .ascii => |ascii| allocator.free(ascii),
                            .utf16 => |utf16| allocator.free(utf16),
                        }
                        allocator.destroy(@constCast(string));
                    };
                    return string.eql(String.fromLiteral(name));
                },
                .numeric_literal => return false,
            },
            .computed_property_name => return false,
        }
    }
};

/// https://tc39.es/ecma262/#prod-RegularExpressionLiteral
pub const RegularExpressionLiteral = struct {
    pattern: []const u8,
    flags: []const u8,

    const ValidationResult = union(enum) {
        valid,
        invalid_pattern: []const u8,
        invalid_flags,
    };

    /// 13.2.7.2 Static Semantics: IsValidRegularExpressionLiteral ( literal )
    /// https://tc39.es/ecma262/#sec-isvalidregularexpressionliteral
    pub fn isValidRegularExpressionLiteral(
        self: RegularExpressionLiteral,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!ValidationResult {
        if (!build_options.enable_libregexp) {
            // Skip validation, throws unconditionally when evaluated
            return .valid;
        }

        // 1. Let flags be the FlagText of literal.
        // 2. If flags contains any code points other than `d`, `g`, `i`, `m`, `s`, `u`, `v`, or
        //    `y`, return false.
        // 3. If flags contains any code point more than once, return false.
        const parsed_flags = libregexp.Flags.parse(self.flags) orelse return .invalid_flags;

        // 4. If flags contains `u`, let u be true; else let u be false.
        // 5. If flags contains `v`, let v be true; else let v be false.
        // 6. Let patternText be the BodyText of literal.
        // 7. If u is false and v is false, then
        //     a. Let stringValue be CodePointsToString(patternText).
        //     b. Set patternText to the sequence of code points resulting from interpreting each of
        //        the 16-bit elements of stringValue as a Unicode BMP code point. UTF-16 decoding is
        //        not applied to the elements.
        // 8. Let parseResult be ParsePattern(patternText, u, v).
        // 9. If parseResult is a Parse Node, return true.
        // 10. Return false.
        // NOTE: Despite passing in the buffer length below, this needs to be null-terminated.
        const buf = if (parsed_flags.unicode or parsed_flags.unicode_sets)
            try allocator.dupeSentinel(u8, self.pattern, 0)
        else blk: {
            var cesu8: std.ArrayList(u8) = try .initCapacity(allocator, self.pattern.len);
            defer cesu8.deinit(allocator);
            var encoded: [6]u8 = undefined;
            var i: usize = 0;
            while (i < self.pattern.len) {
                const len = std.unicode.utf8ByteSequenceLength(self.pattern[i]) catch unreachable;
                const code_point = std.unicode.wtf8Decode(self.pattern[i..][0..len]) catch unreachable;
                if (code_point < 0x10000) {
                    const encoded_len = std.unicode.wtf8Encode(code_point, &encoded) catch unreachable;
                    try cesu8.appendSlice(allocator, encoded[0..encoded_len]);
                } else {
                    const high_len = std.unicode.wtf8Encode(0xd800 | ((code_point - 0x10000) >> 10), &encoded) catch unreachable;
                    const low_len = std.unicode.wtf8Encode(0xdc00 | ((code_point - 0x10000) & 0x3ff), encoded[high_len..]) catch unreachable;
                    try cesu8.appendSlice(allocator, encoded[0 .. high_len + low_len]);
                }
                i += len;
            }
            break :blk try cesu8.toOwnedSliceSentinel(allocator, 0);
        };
        defer allocator.free(buf);
        // TODO: Plumb the resulting bytecode into the created RegExp object somehow.
        var error_msg: []const u8 = undefined;
        _ = libregexp.compile(allocator, buf, parsed_flags, &error_msg) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.LreError => {
                return .{ .invalid_pattern = error_msg };
            },
        };
        return .valid;
    }
};

/// https://tc39.es/ecma262/#prod-TemplateLiteral
pub const TemplateLiteral = struct {
    pub const Span = union(enum) {
        template: Tokenizer.Template,
        expression: Expression,
    };

    spans: []const Span,
};

/// https://tc39.es/ecma262/#prod-UpdateExpression
pub const UpdateExpression = struct {
    pub const Type = enum {
        prefix,
        postfix,
    };

    pub const Operator = enum {
        @"++",
        @"--",
    };

    type: Type,
    operator: Operator,
    expression: *Expression,
};

/// https://tc39.es/ecma262/#prod-UnaryExpression
pub const UnaryExpression = struct {
    pub const Operator = enum {
        delete,
        void,
        typeof,
        @"+",
        @"-",
        @"~",
        @"!",
    };

    operator: Operator,
    expression: *Expression,
};

/// https://tc39.es/ecma262/#prod-ExponentiationExpression
/// https://tc39.es/ecma262/#prod-MultiplicativeExpression
/// https://tc39.es/ecma262/#prod-AdditiveExpression
/// https://tc39.es/ecma262/#prod-ShiftExpression
/// https://tc39.es/ecma262/#prod-BitwiseANDExpression
/// https://tc39.es/ecma262/#prod-BitwiseXORExpression
/// https://tc39.es/ecma262/#prod-BitwiseORExpression
pub const BinaryExpression = struct {
    pub const Operator = enum {
        @"**",
        @"*",
        @"/",
        @"%",
        @"+",
        @"-",
        @"<<",
        @">>",
        @">>>",
        @"&",
        @"^",
        @"|",
    };

    operator: Operator,
    lhs_expression: *Expression,
    rhs_expression: *Expression,
};

/// https://tc39.es/ecma262/#prod-RelationalExpression
pub const RelationalExpression = struct {
    pub const Operator = enum {
        @"<",
        @">",
        @"<=",
        @">=",
        instanceof,
        in,
    };

    pub const Lhs = union(enum) {
        expression: *Expression,
        private_identifier: PrivateIdentifier,
    };

    operator: Operator,
    lhs: Lhs,
    rhs_expression: *Expression,
};

/// https://tc39.es/ecma262/#prod-EqualityExpression
pub const EqualityExpression = struct {
    pub const Operator = enum {
        @"==",
        @"!=",
        @"===",
        @"!==",
    };

    operator: Operator,
    lhs_expression: *Expression,
    rhs_expression: *Expression,
};

/// https://tc39.es/ecma262/#prod-LogicalANDExpression
/// https://tc39.es/ecma262/#prod-LogicalORExpression
/// https://tc39.es/ecma262/#prod-CoalesceExpression
pub const LogicalExpression = struct {
    pub const Operator = enum {
        @"&&",
        @"||",
        @"??",
    };

    operator: Operator,
    lhs_expression: *Expression,
    rhs_expression: *Expression,
};

/// https://tc39.es/ecma262/#prod-ConditionalExpression
pub const ConditionalExpression = struct {
    test_expression: *Expression,
    consequent_expression: *Expression,
    alternate_expression: *Expression,
};

/// https://tc39.es/ecma262/#prod-AssignmentExpression
pub const AssignmentExpression = struct {
    pub const Operator = enum {
        @"=",
        @"*=",
        @"/=",
        @"%=",
        @"+=",
        @"-=",
        @"<<=",
        @">>=",
        @">>>=",
        @"&=",
        @"^=",
        @"|=",
        @"**=",
        @"&&=",
        @"||=",
        @"??=",
    };

    operator: Operator,
    lhs_expression: *Expression,
    rhs_expression: *Expression,
};

pub const SequenceExpression = struct {
    expressions: []const Expression,
};

pub const TaggedTemplate = struct {
    expression: *Expression,
    template_literal: TemplateLiteral,
};

/// https://tc39.es/ecma262/#prod-Expression
pub const Expression = union(enum) {
    primary_expression: PrimaryExpression,
    member_expression: MemberExpression,
    super_property: SuperProperty,
    meta_property: MetaProperty,
    new_expression: NewExpression,
    call_expression: CallExpression,
    super_call: SuperCall,
    import_call: ImportCall,
    optional_expression: OptionalExpression,
    update_expression: UpdateExpression,
    unary_expression: UnaryExpression,
    binary_expression: BinaryExpression,
    relational_expression: RelationalExpression,
    equality_expression: EqualityExpression,
    logical_expression: LogicalExpression,
    conditional_expression: ConditionalExpression,
    assignment_expression: AssignmentExpression,
    sequence_expression: SequenceExpression,
    await_expression: AwaitExpression,
    yield_expression: YieldExpression,
    tagged_template: TaggedTemplate,
    assignment_pattern: AssignmentPattern,

    /// 8.4.3 Static Semantics: IsAnonymousFunctionDefinition ( expr )
    /// https://tc39.es/ecma262/#sec-isanonymousfunctiondefinition
    pub fn isAnonymousFunctionDefinition(self: Expression) bool {
        // 1. If IsFunctionDefinition of expr is false, return false.
        // 2. Let hasName be HasName of expr.
        // 3. If hasName is true, return false.
        // 4. Return true.
        return switch (self) {
            .primary_expression => |prim_expr| switch (prim_expr) {
                .function_expression => |func_expr| func_expr.identifier == null,
                .generator_expression => |gen_expr| gen_expr.identifier == null,
                .async_function_expression => |async_expr| async_expr.identifier == null,
                .async_generator_expression => |async_gen_expr| async_gen_expr.identifier == null,
                .class_expression => |class_expr| class_expr.identifier == null,
                .arrow_function => true,
                .async_arrow_function => true,
                else => false,
            },
            else => false,
        };
    }

    /// 8.6.4 Static Semantics: AssignmentTargetType
    /// https://tc39.es/ecma262/#sec-static-semantics-assignmenttargettype
    pub fn assignmentTargetType(self: Expression, is_strict: ?bool) enum { simple, web_compat, invalid } {
        switch (self) {
            // IdentifierReference : Identifier
            // IdentifierReference :
            //     yield
            //     await
            .primary_expression => |primary_expression| if (primary_expression == .identifier_reference) {
                // 1. If IsStrict(this IdentifierReference) is true and the StringValue of
                //    Identifier is either "eval" or "arguments", return invalid.
                const name = self.primary_expression.identifier_reference;
                if (is_strict == true and
                    (std.mem.eql(u8, name, "eval") or std.mem.eql(u8, name, "arguments")))
                {
                    return .invalid;
                }

                // 2. Return simple.
                return .simple;
            },

            // CallExpression :
            //     CallExpression [ Expression ]
            //     CallExpression . IdentifierName
            //     CallExpression . PrivateIdentifier
            // MemberExpression :
            //     MemberExpression [ Expression ]
            //     MemberExpression . IdentifierName
            //     SuperProperty
            //     MemberExpression . PrivateIdentifier
            .member_expression,
            .super_property,
            => {
                // 1. Return simple.
                return .simple;
            },

            // CallExpression :
            //     CoverCallExpressionAndAsyncArrowHead
            //     CallExpression Arguments
            .call_expression => {
                // 1. If the host is a web browser or otherwise supports Runtime Errors for Function
                //    Call Assignment Targets and IsStrict(this CallExpression) is false, then
                //     a. Return web-compat.
                // The strictness is passed as a nullable boolean as we only have to check it
                // during parsing, in codegen we know the assignment target type is simple or
                // web-compat.
                if (build_options.enable_annex_b and is_strict != true) {
                    return .web_compat;
                }

                // 2. Return invalid.
                return .invalid;
            },

            else => {},
        }

        // 1. Return invalid.
        return .invalid;
    }

    pub fn analyze(self: Expression, query: AnalyzeQuery) bool {
        return switch (query) {
            .is_await_expression => switch (self) {
                .await_expression => true,
                .primary_expression => |primary_expression| primary_expression.analyze(query),
                else => false,
            },
            .is_member_expression => switch (self) {
                .member_expression => true,
                .primary_expression => |primary_expression| primary_expression.analyze(query),
                else => false,
            },
            .is_reference => switch (self) {
                .member_expression,
                .super_property,
                // NOTE: optional_expression is omitted here on purpose, codegenOptionalExpression() always resolves references.
                => true,
                .primary_expression => |primary_expression| primary_expression.analyze(query),
                else => false,
            },
            else => switch (self) {
                .primary_expression => |primary_expression| primary_expression.analyze(query),
                else => false,
            },
        };
    }

    pub fn endsWithPrivateIdentifier(self: Expression) bool {
        return switch (self) {
            .member_expression => |member_expression| switch (member_expression.property) {
                .expression => |expression| expression.endsWithPrivateIdentifier(),
                .identifier => false,
                .private_identifier => true,
            },
            .optional_expression => |optional_expression| {
                const last = optional_expression.properties[optional_expression.properties.len - 1];
                return switch (last) {
                    .expression => |expression| expression.endsWithPrivateIdentifier(),
                    .arguments, .identifier => false,
                    .private_identifier => true,
                };
            },
            else => false,
        };
    }
};

/// https://tc39.es/ecma262/#prod-Statement
pub const Statement = union(enum) {
    block_statement: BlockStatement,
    variable_statement: VariableStatement,
    empty_statement,
    expression_statement: ExpressionStatement,
    if_statement: IfStatement,
    breakable_statement: BreakableStatement,
    continue_statement: ContinueStatement,
    break_statement: BreakStatement,
    return_statement: ReturnStatement,
    with_statement: WithStatement,
    labelled_statement: LabelledStatement,
    throw_statement: ThrowStatement,
    try_statement: TryStatement,
    debugger_statement,

    pub fn analyze(self: Statement, query: AnalyzeQuery) bool {
        return switch (query) {
            .is_await_expression,
            .is_identifier_reference,
            .is_member_expression,
            .is_reference,
            .is_string_literal,
            => switch (self) {
                .expression_statement => |expression_statement| expression_statement.expression.analyze(query),
                else => false,
            },
        };
    }

    /// 8.2.8 Static Semantics: VarDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-vardeclarednames
    pub fn collectVarDeclaredNames(
        self: Statement,
        allocator: std.mem.Allocator,
        var_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        switch (self) {
            // Statement :
            //     EmptyStatement
            //     ExpressionStatement
            //     ContinueStatement
            //     BreakStatement
            //     ReturnStatement
            //     ThrowStatement
            //     DebuggerStatement
            // 1. Return a new empty List.
            .empty_statement,
            .expression_statement,
            .continue_statement,
            .break_statement,
            .return_statement,
            .throw_statement,
            .debugger_statement,
            => {},

            .block_statement => |block_statement| try block_statement.block.statement_list.collectVarDeclaredNames(allocator, var_declared_names),
            .variable_statement => |variable_statement| try variable_statement.variable_declaration_list.collectVarDeclaredNames(allocator, var_declared_names),
            .if_statement => |if_statement| try if_statement.collectVarDeclaredNames(allocator, var_declared_names),
            .breakable_statement => |breakable_statement| switch (breakable_statement) {
                .iteration_statement => |iteration_statement| switch (iteration_statement) {
                    inline else => |node| try node.collectVarDeclaredNames(allocator, var_declared_names),
                },
                .switch_statement => |switch_statement| try switch_statement.collectVarDeclaredNames(allocator, var_declared_names),
            },
            .with_statement => |with_statement| try with_statement.collectVarDeclaredNames(allocator, var_declared_names),
            .labelled_statement => |labelled_statement| try labelled_statement.collectVarDeclaredNames(allocator, var_declared_names),
            .try_statement => |try_statement| try try_statement.collectVarDeclaredNames(allocator, var_declared_names),
        }
    }

    /// 8.2.9 Static Semantics: VarScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-varscopeddeclarations
    pub fn collectVarScopedDeclarations(
        self: Statement,
        allocator: std.mem.Allocator,
        var_scoped_declarations: *std.ArrayList(VarScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        switch (self) {
            // Statement :
            //     EmptyStatement
            //     ExpressionStatement
            //     ContinueStatement
            //     BreakStatement
            //     ReturnStatement
            //     ThrowStatement
            //     DebuggerStatement
            // 1. Return a new empty List.
            .empty_statement,
            .expression_statement,
            .continue_statement,
            .break_statement,
            .return_statement,
            .throw_statement,
            .debugger_statement,
            => {},

            .block_statement => |block_statement| try block_statement.block.statement_list.collectVarScopedDeclarations(allocator, var_scoped_declarations),
            .variable_statement => |variable_statement| try variable_statement.variable_declaration_list.collectVarScopedDeclarations(allocator, var_scoped_declarations),
            .if_statement => |if_statement| try if_statement.collectVarScopedDeclarations(allocator, var_scoped_declarations),
            .breakable_statement => |breakable_statement| switch (breakable_statement) {
                .iteration_statement => |iteration_statement| switch (iteration_statement) {
                    inline else => |node| try node.collectVarScopedDeclarations(allocator, var_scoped_declarations),
                },
                .switch_statement => |switch_statement| try switch_statement.collectVarScopedDeclarations(allocator, var_scoped_declarations),
            },
            .with_statement => |with_statement| try with_statement.collectVarScopedDeclarations(allocator, var_scoped_declarations),
            .labelled_statement => |labelled_statement| try labelled_statement.collectVarScopedDeclarations(allocator, var_scoped_declarations),
            .try_statement => |try_statement| try try_statement.collectVarScopedDeclarations(allocator, var_scoped_declarations),
        }
    }
};

/// https://tc39.es/ecma262/#prod-Declaration
pub const Declaration = union(enum) {
    hoistable_declaration: HoistableDeclaration,
    class_declaration: ClassDeclaration,
    lexical_declaration: LexicalDeclaration,

    pub fn analyze(_: Declaration, query: AnalyzeQuery) bool {
        return switch (query) {
            .is_await_expression,
            .is_identifier_reference,
            .is_member_expression,
            .is_reference,
            .is_string_literal,
            => false,
        };
    }

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: Declaration,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        switch (self) {
            inline else => |node| try node.collectBoundNames(allocator, bound_names),
        }
    }

    /// 8.2.4 Static Semantics: IsUsingDeclaration
    /// https://tc39.es/ecma262/#sec-static-semantics-isusingdeclaration
    pub fn isUsingDeclaration(self: Declaration) bool {
        // LexicalDeclaration : LetOrConst BindingList ;
        // 1. Return false.
        // UsingDeclaration : using BindingList ;
        // 1. Return true.
        // AwaitUsingDeclaration : CoverAwaitExpressionAndAwaitUsingDeclarationHead BindingList ;
        // 1. Return false.
        // ForDeclaration : LetOrConst ForBinding
        // 1. Return false.
        // ForDeclaration : using ForBinding
        // 1. Return true.
        // ForDeclaration : await using ForBinding
        // 1. Return false.
        return switch (self) {
            .lexical_declaration => |lex_decl| lex_decl.type == .using,
            else => false,
        };
    }

    /// 8.2.5 Static Semantics: IsAwaitUsingDeclaration
    /// https://tc39.es/ecma262/#sec-static-semantics-isawaitusingdeclaration
    pub fn isAwaitUsingDeclaration(self: Declaration) bool {
        // LexicalDeclaration : LetOrConst BindingList ;
        // 1. Return false.
        // UsingDeclaration : using BindingList ;
        // 1. Return false.
        // AwaitUsingDeclaration : CoverAwaitExpressionAndAwaitUsingDeclarationHead BindingList ;
        // 1. Return true.
        // ForDeclaration : LetOrConst ForBinding
        // 1. Return false.
        // ForDeclaration : using ForBinding
        // 1. Return false.
        // ForDeclaration : await using ForBinding
        // 1. Return true.
        return switch (self) {
            .lexical_declaration => |lex_decl| lex_decl.type == .await_using,
            else => false,
        };
    }
};

/// https://tc39.es/ecma262/#prod-HoistableDeclaration
pub const HoistableDeclaration = union(enum) {
    function_declaration: FunctionDeclaration,
    generator_declaration: GeneratorDeclaration,
    async_function_declaration: AsyncFunctionDeclaration,
    async_generator_declaration: AsyncGeneratorDeclaration,

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: HoistableDeclaration,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        switch (self) {
            inline else => |node| try node.collectBoundNames(allocator, bound_names),
        }
    }

    /// 8.2.3 Static Semantics: IsConstantDeclaration
    /// https://tc39.es/ecma262/#sec-static-semantics-isconstantdeclaration
    pub fn isConstantDeclaration(self: HoistableDeclaration) bool {
        switch (self) {
            inline else => |node| return node.isConstantDeclaration(),
        }
    }
};

/// https://tc39.es/ecma262/#prod-BreakableStatement
pub const BreakableStatement = union(enum) {
    iteration_statement: IterationStatement,
    switch_statement: SwitchStatement,
};

/// https://tc39.es/ecma262/#prod-BlockStatement
pub const BlockStatement = struct {
    block: Block,
};

/// https://tc39.es/ecma262/#prod-Block
pub const Block = struct {
    statement_list: StatementList,
};

/// https://tc39.es/ecma262/#prod-StatementList
pub const StatementList = struct {
    items: []const StatementListItem,

    pub fn hasLexicallyScopedDeclarations(self: StatementList) bool {
        for (self.items) |item| {
            if (item.hasLexicallyScopedDeclarations()) return true;
        }
        return false;
    }

    /// 8.2.6 Static Semantics: LexicallyDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-lexicallydeclarednames
    pub fn collectLexicallyDeclaredNames(
        self: StatementList,
        allocator: std.mem.Allocator,
        lexically_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // StatementList : StatementList StatementListItem
        // 1. Let names1 be the LexicallyDeclaredNames of StatementList.
        // 2. Let names2 be the LexicallyDeclaredNames of StatementListItem.
        // 3. Return the list-concatenation of names1 and names2.
        for (self.items) |item| {
            try item.collectLexicallyDeclaredNames(allocator, lexically_declared_names);
        }
    }

    /// 8.2.7 Static Semantics: LexicallyScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-lexicallyscopeddeclarations
    pub fn collectLexicallyScopedDeclarations(
        self: StatementList,
        allocator: std.mem.Allocator,
        lexically_scoped_declarations: *std.ArrayList(LexicallyScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // StatementList : StatementList StatementListItem
        // 1. Let decls1 be the LexicallyScopedDeclarations of StatementList.
        // 2. Let decls2 be the LexicallyScopedDeclarations of StatementListItem.
        // 3. Return the list-concatenation of decls1 and decls2.
        for (self.items) |item| {
            try item.collectLexicallyScopedDeclarations(allocator, lexically_scoped_declarations);
        }
    }

    /// 8.2.8 Static Semantics: VarDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-vardeclarednames
    pub fn collectVarDeclaredNames(
        self: StatementList,
        allocator: std.mem.Allocator,
        var_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // StatementList : StatementList StatementListItem
        // 1. Let names1 be the VarDeclaredNames of StatementList.
        // 2. Let names2 be the VarDeclaredNames of StatementListItem.
        // 3. Return the list-concatenation of names1 and names2.
        // StatementListItem : Declaration
        // 1. Return a new empty List.
        for (self.items) |item| {
            try item.collectVarDeclaredNames(allocator, var_declared_names);
        }
    }

    /// 8.2.9 Static Semantics: VarScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-varscopeddeclarations
    pub fn collectVarScopedDeclarations(
        self: StatementList,
        allocator: std.mem.Allocator,
        var_scoped_declarations: *std.ArrayList(VarScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // StatementList : StatementList StatementListItem
        // 1. Let decls1 be the VarScopedDeclarations of StatementList.
        // 2. Let decls2 be the VarScopedDeclarations of StatementListItem.
        // 3. Return the list-concatenation of decls1 and decls2.
        // StatementListItem : Declaration
        // 1. Return a new empty List.
        for (self.items) |item| {
            try item.collectVarScopedDeclarations(allocator, var_scoped_declarations);
        }
    }

    /// 8.2.10 Static Semantics: TopLevelLexicallyDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-toplevellexicallydeclarednames
    pub fn collectTopLevelLexicallyDeclaredNames(
        self: StatementList,
        allocator: std.mem.Allocator,
        lexically_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // StatementList : StatementList StatementListItem
        // 1. Let names1 be the TopLevelLexicallyDeclaredNames of StatementList.
        // 2. Let names2 be the TopLevelLexicallyDeclaredNames of StatementListItem.
        // 3. Return the list-concatenation of names1 and names2.
        for (self.items) |item| {
            try item.collectTopLevelLexicallyDeclaredNames(allocator, lexically_declared_names);
        }
    }

    /// 8.2.11 Static Semantics: TopLevelLexicallyScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-toplevellexicallyscopeddeclarations
    pub fn collectTopLevelLexicallyScopedDeclarations(
        self: StatementList,
        allocator: std.mem.Allocator,
        lexically_scoped_declarations: *std.ArrayList(LexicallyScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // StatementList : StatementList StatementListItem
        // 1. Let decls1 be the TopLevelLexicallyScopedDeclarations of StatementList.
        // 2. Let decls2 be the TopLevelLexicallyScopedDeclarations of StatementListItem.
        // 3. Return the list-concatenation of decls1 and decls2.
        for (self.items) |item| {
            try item.collectTopLevelLexicallyScopedDeclarations(allocator, lexically_scoped_declarations);
        }
    }

    /// 8.2.12 Static Semantics: TopLevelVarDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-toplevelvardeclarednames
    pub fn collectTopLevelVarDeclaredNames(
        self: StatementList,
        allocator: std.mem.Allocator,
        var_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // StatementList : StatementList StatementListItem
        // 1. Let names1 be the TopLevelVarDeclaredNames of StatementList.
        // 2. Let names2 be the TopLevelVarDeclaredNames of StatementListItem.
        // 3. Return the list-concatenation of names1 and names2.
        for (self.items) |item| switch (item) {
            // StatementListItem : Statement
            .statement => |statement| {
                // 1. If Statement is Statement : LabelledStatement , return the
                //    TopLevelVarDeclaredNames of Statement.
                if (statement.* == .labelled_statement) {
                    try statement.labelled_statement.collectTopLevelVarDeclaredNames(allocator, var_declared_names);
                }
                // 2. Return the VarDeclaredNames of Statement.
                else {
                    try statement.collectVarDeclaredNames(allocator, var_declared_names);
                }
            },
            // StatementListItem : Declaration
            .declaration => |declaration| {
                switch (declaration.*) {
                    // 1. If Declaration is Declaration : HoistableDeclaration , then
                    .hoistable_declaration => |hoistable_declaration| {
                        // a. Return the BoundNames of HoistableDeclaration.
                        try hoistable_declaration.collectBoundNames(allocator, var_declared_names);
                    },

                    // 2. Return a new empty List.
                    else => {},
                }
            },
        };
    }

    /// 8.2.13 Static Semantics: TopLevelVarScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-toplevelvarscopeddeclarations
    pub fn collectTopLevelVarScopedDeclarations(
        self: StatementList,
        allocator: std.mem.Allocator,
        var_scoped_declarations: *std.ArrayList(VarScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // StatementList : StatementList StatementListItem
        // 1. Let decls1 be the TopLevelVarScopedDeclarations of StatementList.
        // 2. Let decls2 be the TopLevelVarScopedDeclarations of StatementListItem.
        // 3. Return the list-concatenation of decls1 and decls2.
        for (self.items) |item| switch (item) {
            // StatementListItem : Statement
            .statement => |statement| {
                // 1. If Statement is Statement : LabelledStatement , return the
                //    TopLevelVarScopedDeclarations of Statement.
                if (statement.* == .labelled_statement) {
                    try statement.labelled_statement.collectTopLevelVarScopedDeclarations(allocator, var_scoped_declarations);
                }
                // 2. Return the VarScopedDeclarations of Statement.
                else {
                    try statement.collectVarScopedDeclarations(allocator, var_scoped_declarations);
                }
            },
            // StatementListItem : Declaration
            .declaration => |declaration| {
                switch (declaration.*) {
                    // 1. If Declaration is Declaration : HoistableDeclaration , then
                    .hoistable_declaration => |hoistable_declaration| {
                        // a. Let decl be the DeclarationPart of HoistableDeclaration.
                        // b. Return « decl ».
                        try var_scoped_declarations.append(allocator, .{ .hoistable_declaration = hoistable_declaration });
                    },

                    // 2. Return a new empty List.
                    else => {},
                }
            },
        };
    }

    /// 8.6.6 Static Semantics: ContainsUsing
    /// https://tc39.es/ecma262/#sec-static-semantics-containsusing
    pub fn containsUsing(self: StatementList) bool {
        // StatementList : StatementList StatementListItem
        // 1. If ContainsUsing of the derived StatementList is true, return true.
        // 2. If ContainsUsing of StatementListItem is true, return true.
        // 3. Return false.
        for (self.items) |item| {
            if (item.containsUsing()) return true;
        }
        return false;
    }

    /// 11.2.1 Directive Prologues and the Use Strict Directive
    /// https://tc39.es/ecma262/#sec-directive-prologues-and-the-use-strict-directive
    pub fn containsDirective(self: StatementList, directive: []const u8) bool {
        for (self.items) |item| {
            if (!item.analyze(.is_string_literal)) break;
            const string_literal = item.statement.expression_statement.expression.primary_expression.literal.string;
            const raw_string_value = string_literal.text[1 .. string_literal.text.len - 1];
            if (std.mem.eql(u8, raw_string_value, directive)) return true;
        }
        return false;
    }
};

/// https://tc39.es/ecma262/#prod-StatementListItem
pub const StatementListItem = union(enum) {
    statement: *Statement,
    declaration: *Declaration,

    pub fn hasLexicallyScopedDeclarations(self: StatementListItem) bool {
        return switch (self) {
            .statement => |statement| switch (statement.*) {
                .labelled_statement => |labelled_statement| labelled_statement.hasLexicallyScopedDeclarations(),
                else => false,
            },
            .declaration => true,
        };
    }

    /// 8.2.6 Static Semantics: LexicallyDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-lexicallydeclarednames
    pub fn collectLexicallyDeclaredNames(
        self: StatementListItem,
        allocator: std.mem.Allocator,
        lexically_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        switch (self) {
            // StatementListItem : Statement
            .statement => |statement| switch (statement.*) {
                // 1. If Statement is Statement : LabelledStatement , return the
                //    LexicallyDeclaredNames of LabelledStatement.
                .labelled_statement => |labelled_statement| {
                    try labelled_statement.collectLexicallyDeclaredNames(allocator, lexically_declared_names);
                },

                // 2. Return a new empty List.
                else => {},
            },

            // StatementListItem : Declaration
            .declaration => |declaration| {
                // 1. Return the BoundNames of Declaration.
                try declaration.collectBoundNames(allocator, lexically_declared_names);
            },
        }
    }

    /// 8.2.7 Static Semantics: LexicallyScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-lexicallyscopeddeclarations
    pub fn collectLexicallyScopedDeclarations(
        self: StatementListItem,
        allocator: std.mem.Allocator,
        lexically_scoped_declarations: *std.ArrayList(LexicallyScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        switch (self) {
            // StatementListItem : Statement
            .statement => |statement| switch (statement.*) {
                // 1. If Statement is Statement : LabelledStatement , return the
                //    LexicallyScopedDeclarations of LabelledStatement.
                .labelled_statement => |labelled_statement| {
                    try labelled_statement.collectLexicallyScopedDeclarations(allocator, lexically_scoped_declarations);
                },

                // 2. Return a new empty List.
                else => {},
            },

            // StatementListItem : Declaration
            .declaration => |declaration| switch (declaration.*) {
                // 1. Return a List whose sole element is the DeclarationPart of Declaration.
                .hoistable_declaration => |hoistable_declaration| try lexically_scoped_declarations.append(allocator, .{ .hoistable_declaration = hoistable_declaration }),
                .class_declaration => |class_declaration| try lexically_scoped_declarations.append(allocator, .{ .class_declaration = class_declaration }),
                .lexical_declaration => |lexical_declaration| try lexically_scoped_declarations.append(allocator, .{ .lexical_declaration = lexical_declaration }),
            },
        }
    }

    /// 8.2.8 Static Semantics: VarDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-vardeclarednames
    pub fn collectVarDeclaredNames(
        self: StatementListItem,
        allocator: std.mem.Allocator,
        var_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        switch (self) {
            .statement => |statement| try statement.collectVarDeclaredNames(allocator, var_declared_names),
            .declaration => {},
        }
    }

    /// 8.2.9 Static Semantics: VarScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-varscopeddeclarations
    pub fn collectVarScopedDeclarations(
        self: StatementListItem,
        allocator: std.mem.Allocator,
        var_scoped_declarations: *std.ArrayList(VarScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        switch (self) {
            .statement => |statement| try statement.collectVarScopedDeclarations(allocator, var_scoped_declarations),
            .declaration => {},
        }
    }

    /// 8.2.10 Static Semantics: TopLevelLexicallyDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-toplevellexicallydeclarednames
    pub fn collectTopLevelLexicallyDeclaredNames(
        self: StatementListItem,
        allocator: std.mem.Allocator,
        lexically_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        switch (self) {
            // StatementListItem : Statement
            .statement => {
                // 1. Return a new empty List.
            },

            // StatementListItem : Declaration
            .declaration => |declaration| switch (declaration.*) {
                // 1. If Declaration is Declaration : HoistableDeclaration , then
                .hoistable_declaration => {
                    // a. Return a new empty List.
                },

                // 2. Return the BoundNames of Declaration.
                .class_declaration => |class_declaration| try class_declaration.collectBoundNames(allocator, lexically_declared_names),
                .lexical_declaration => |lexical_declaration| try lexical_declaration.collectBoundNames(allocator, lexically_declared_names),
            },
        }
    }

    /// 8.2.11 Static Semantics: TopLevelLexicallyScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-toplevellexicallyscopeddeclarations
    pub fn collectTopLevelLexicallyScopedDeclarations(
        self: StatementListItem,
        allocator: std.mem.Allocator,
        lexically_scoped_declarations: *std.ArrayList(LexicallyScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        switch (self) {
            // StatementListItem : Statement
            .statement => {
                // 1. Return a new empty List.
            },

            // StatementListItem : Declaration
            .declaration => |declaration| switch (declaration.*) {
                // 1. If Declaration is Declaration : HoistableDeclaration , then
                .hoistable_declaration => {
                    // a. Return a new empty List.
                },

                // 2. Return « Declaration ».
                .class_declaration => |class_declaration| try lexically_scoped_declarations.append(allocator, .{ .class_declaration = class_declaration }),
                .lexical_declaration => |lexical_declaration| try lexically_scoped_declarations.append(allocator, .{ .lexical_declaration = lexical_declaration }),
            },
        }
    }

    /// 8.6.6 Static Semantics: ContainsUsing
    /// https://tc39.es/ecma262/#sec-static-semantics-containsusing
    pub fn containsUsing(self: StatementListItem) bool {
        // StatementListItem : Statement
        // 1. Return false.
        // StatementListItem : Declaration
        // 1. If IsUsingDeclaration of Declaration is true, return true.
        // 2. If IsAwaitUsingDeclaration of Declaration is true, return true.
        // 3. Return false.
        return switch (self) {
            .statement => false,
            .declaration => |declaration| declaration.isUsingDeclaration() or declaration.isAwaitUsingDeclaration(),
        };
    }

    pub fn analyze(self: StatementListItem, query: AnalyzeQuery) bool {
        return switch (self) {
            inline else => |node| node.analyze(query),
        };
    }
};

/// https://tc39.es/ecma262/#prod-LexicalDeclaration
pub const LexicalDeclaration = struct {
    pub const Type = enum {
        let,
        @"const",
        using,
        await_using,
    };

    type: Type,
    binding_list: BindingList,

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: LexicalDeclaration,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // LexicalDeclaration : LetOrConst BindingList ;
        // 1. Return the BoundNames of BindingList.
        // UsingDeclaration :
        //     using BindingList ;
        // AwaitUsingDeclaration :
        //     CoverAwaitExpressionAndAwaitUsingDeclarationHead BindingList ;
        // 1. Return the BoundNames of BindingList.
        try self.binding_list.collectBoundNames(allocator, bound_names);
    }

    /// 8.2.3 Static Semantics: IsConstantDeclaration
    /// https://tc39.es/ecma262/#sec-static-semantics-isconstantdeclaration
    pub fn isConstantDeclaration(self: LexicalDeclaration) bool {
        // LexicalDeclaration : LetOrConst BindingList ;
        // 1. Return IsConstantDeclaration of LetOrConst.
        // LetOrConst : let
        // 1. Return false.
        // LetOrConst : const
        // 1. Return true.
        // UsingDeclaration :
        //     using BindingList ;
        // AwaitUsingDeclaration :
        //     CoverAwaitExpressionAndAwaitUsingDeclarationHead BindingList ;
        // 1. Return true.
        return switch (self.type) {
            .let => false,
            else => true,
        };
    }
};

/// https://tc39.es/ecma262/#prod-BindingList
pub const BindingList = struct {
    items: []const LexicalBinding,

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: BindingList,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // BindingList : BindingList , LexicalBinding
        // 1. Let names1 be the BoundNames of BindingList.
        // 2. Let names2 be the BoundNames of LexicalBinding.
        // 3. Return the list-concatenation of names1 and names2.
        for (self.items) |lexical_binding| {
            try lexical_binding.collectBoundNames(allocator, bound_names);
        }
    }
};

/// https://tc39.es/ecma262/#prod-LexicalBinding
pub const LexicalBinding = union(enum) {
    binding_identifier: struct {
        binding_identifier: Identifier,
        initializer: ?Expression,
    },
    binding_pattern: struct {
        binding_pattern: BindingPattern,
        initializer: Expression,
    },

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: LexicalBinding,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        switch (self) {
            // LexicalBinding : BindingIdentifier Initializer[opt]
            .binding_identifier => |binding_identifier| {
                // 1. Return the BoundNames of BindingIdentifier.
                try bound_names.append(allocator, binding_identifier.binding_identifier);
            },
            // LexicalBinding : BindingPattern Initializer
            .binding_pattern => |binding_pattern| {
                // 1. Return the BoundNames of BindingPattern.
                try binding_pattern.binding_pattern.collectBoundNames(allocator, bound_names);
            },
        }
    }
};

/// https://tc39.es/ecma262/#prod-VariableStatement
pub const VariableStatement = struct {
    variable_declaration_list: VariableDeclarationList,
};

/// https://tc39.es/ecma262/#prod-VariableDeclarationList
pub const VariableDeclarationList = struct {
    items: []const VariableDeclaration,

    /// 8.2.8 Static Semantics: VarDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-vardeclarednames
    pub fn collectVarDeclaredNames(
        self: VariableDeclarationList,
        allocator: std.mem.Allocator,
        var_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // VariableStatement : var VariableDeclarationList ;
        // 1. Return the BoundNames of VariableDeclarationList.
        try self.collectBoundNames(allocator, var_declared_names);
    }

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: VariableDeclarationList,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // VariableDeclarationList : VariableDeclarationList , VariableDeclaration
        // 1. Let names1 be the BoundNames of VariableDeclarationList.
        // 2. Let names2 be the BoundNames of VariableDeclaration.
        // 3. Return the list-concatenation of names1 and names2.
        // VariableDeclaration : BindingIdentifier Initializer[opt]
        // 1. Return the BoundNames of BindingIdentifier.
        for (self.items) |variable_declaration| {
            try variable_declaration.collectBoundNames(allocator, bound_names);
        }
    }

    /// 8.2.9 Static Semantics: VarScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-varscopeddeclarations
    pub fn collectVarScopedDeclarations(
        self: VariableDeclarationList,
        allocator: std.mem.Allocator,
        var_scoped_declarations: *std.ArrayList(VarScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // VariableDeclarationList : VariableDeclaration
        // 1. Return « VariableDeclaration ».
        // VariableDeclarationList : VariableDeclarationList , VariableDeclaration
        // 1. Let decls1 be the VarScopedDeclarations of VariableDeclarationList.
        // 2. Return the list-concatenation of decls1 and « VariableDeclaration ».
        try var_scoped_declarations.ensureUnusedCapacity(allocator, self.items.len);
        for (self.items) |variable_declaration| {
            var_scoped_declarations.appendAssumeCapacity(.{ .variable_declaration = variable_declaration });
        }
    }
};

/// https://tc39.es/ecma262/#prod-VariableDeclaration
pub const VariableDeclaration = union(enum) {
    binding_identifier: struct {
        binding_identifier: Identifier,
        initializer: ?Expression,
    },
    binding_pattern: struct {
        binding_pattern: BindingPattern,
        initializer: Expression,
    },

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: VariableDeclaration,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        switch (self) {
            // VariableDeclaration : BindingIdentifier Initializer[opt]
            .binding_identifier => |binding_identifier| {
                // 1. Return the BoundNames of BindingIdentifier.
                try bound_names.append(allocator, binding_identifier.binding_identifier);
            },
            // VariableDeclaration : BindingPattern Initializer
            .binding_pattern => |binding_pattern| {
                // 1. Return the BoundNames of BindingPattern.
                try binding_pattern.binding_pattern.collectBoundNames(allocator, bound_names);
            },
        }
    }
};

/// https://tc39.es/ecma262/#prod-AssignmentPattern
pub const AssignmentPattern = union(enum) {
    object_assignment_pattern: ObjectAssignmentPattern,
    array_assignment_pattern: ArrayAssignmentPattern,
};

/// https://tc39.es/ecma262/#prod-ObjectAssignmentPattern
pub const ObjectAssignmentPattern = struct {
    pub const Property = union(enum) {
        assignment_property: AssignmentProperty,
        assignment_rest_property: AssignmentRestProperty,
    };

    properties: []const Property,
};

/// https://tc39.es/ecma262/#prod-ArrayAssignmentPattern
pub const ArrayAssignmentPattern = struct {
    pub const Element = union(enum) {
        elision,
        assignment_element: AssignmentElement,
        assignment_rest_element: AssignmentRestElement,
    };

    elements: []const Element,
};

/// https://tc39.es/ecma262/#prod-AssignmentRestProperty
pub const AssignmentRestProperty = struct {
    destructuring_assignment_target: DestructuringAssignmentTarget,
};

/// https://tc39.es/ecma262/#prod-AssignmentProperty
pub const AssignmentProperty = union(enum) {
    pub const IdentifierReferenceAndExpression = struct {
        identifier_reference: IdentifierReference,
        initializer: ?Expression,
    };

    pub const PropertyNameAndAssignmentElement = struct {
        property_name: PropertyName,
        assignment_element: AssignmentElement,
    };

    identifier_reference_and_expression: IdentifierReferenceAndExpression,
    property_name_and_assignment_element: PropertyNameAndAssignmentElement,
};

/// https://tc39.es/ecma262/#prod-AssignmentElement
pub const AssignmentElement = struct {
    destructuring_assignment_target: DestructuringAssignmentTarget,
    initializer: ?Expression,
};

/// https://tc39.es/ecma262/#prod-AssignmentRestElement
pub const AssignmentRestElement = struct {
    destructuring_assignment_target: DestructuringAssignmentTarget,
};

/// https://tc39.es/ecma262/#prod-DestructuringAssignmentTarget
pub const DestructuringAssignmentTarget = union(enum) {
    identifier_reference: IdentifierReference,
    member_expression: MemberExpression,
    super_property: SuperProperty,
    assignment_pattern: AssignmentPattern,
};

/// https://tc39.es/ecma262/#prod-BindingPattern
pub const BindingPattern = union(enum) {
    object_binding_pattern: ObjectBindingPattern,
    array_binding_pattern: ArrayBindingPattern,

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: BindingPattern,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        switch (self) {
            // ObjectBindingPattern : { }
            // ObjectBindingPattern : { BindingPropertyList , BindingRestProperty }
            .object_binding_pattern => |object_binding_pattern| for (object_binding_pattern.properties) |property| switch (property) {
                .binding_property => |binding_property| try binding_property.collectBoundNames(allocator, bound_names),
                .binding_rest_property => |binding_rest_property| try bound_names.append(allocator, binding_rest_property.binding_identifier),
            },

            // ArrayBindingPattern : [ Elision[opt] ]
            //     1. Return a new empty List.
            .array_binding_pattern => |array_binding_pattern| for (array_binding_pattern.elements) |element| switch (element) {
                .elision => {},
                .binding_element => |binding_element| try binding_element.collectBoundNames(allocator, bound_names),
                .binding_rest_element => |binding_rest_element| switch (binding_rest_element) {
                    .binding_identifier => |binding_identifier| try bound_names.append(allocator, binding_identifier),
                    .binding_pattern => |binding_pattern| try binding_pattern.collectBoundNames(allocator, bound_names),
                },
            },
        }
    }

    /// 15.1.2 Static Semantics: ContainsExpression
    /// https://tc39.es/ecma262/#sec-static-semantics-containsexpression
    pub fn containsExpression(self: BindingPattern) bool {
        switch (self) {
            .object_binding_pattern => |object_binding_pattern| for (object_binding_pattern.properties) |property| switch (property) {
                .binding_property => |binding_property| if (binding_property.containsExpression()) return true,
                .binding_rest_property => {},
            },
            .array_binding_pattern => |array_binding_pattern| for (array_binding_pattern.elements) |element| switch (element) {
                .elision => {},
                .binding_element => |binding_element| if (binding_element.containsExpression()) return true,
                .binding_rest_element => |binding_rest_element| if (binding_rest_element.containsExpression()) return true,
            },
        }
        return false;
    }
};

/// https://tc39.es/ecma262/#prod-ObjectBindingPattern
pub const ObjectBindingPattern = struct {
    pub const Property = union(enum) {
        binding_property: BindingProperty,
        binding_rest_property: BindingRestProperty,
    };

    properties: []const Property,
};

/// https://tc39.es/ecma262/#prod-ArrayBindingPattern
pub const ArrayBindingPattern = struct {
    pub const Element = union(enum) {
        elision,
        binding_element: BindingElement,
        binding_rest_element: BindingRestElement,
    };

    elements: []const Element,
};

/// https://tc39.es/ecma262/#prod-BindingRestProperty
pub const BindingRestProperty = struct {
    binding_identifier: Identifier,
};

/// https://tc39.es/ecma262/#prod-BindingProperty
pub const BindingProperty = union(enum) {
    pub const PropertyNameAndBindingElement = struct {
        property_name: PropertyName,
        binding_element: BindingElement,
    };

    single_name_binding: SingleNameBinding,
    property_name_and_binding_element: PropertyNameAndBindingElement,

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: BindingProperty,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // BindingProperty : PropertyName : BindingElement
        // 1. Return the BoundNames of BindingElement.
        switch (self) {
            .single_name_binding => |single_name_binding| try single_name_binding.collectBoundNames(allocator, bound_names),
            .property_name_and_binding_element => |property_name_and_binding_element| {
                try property_name_and_binding_element.binding_element.collectBoundNames(allocator, bound_names);
            },
        }
    }

    /// 15.1.2 Static Semantics: ContainsExpression
    /// https://tc39.es/ecma262/#sec-static-semantics-containsexpression
    pub fn containsExpression(self: BindingProperty) bool {
        // BindingProperty : PropertyName : BindingElement
        // 1. Let has be IsComputedPropertyKey of PropertyName.
        // 2. If has is true, return true.
        // 3. Return ContainsExpression of BindingElement.
        return switch (self) {
            .single_name_binding => |single_name_binding| single_name_binding.initializer != null,
            .property_name_and_binding_element => |property_name_and_binding_element| false or
                property_name_and_binding_element.property_name == .computed_property_name or
                property_name_and_binding_element.binding_element.containsExpression(),
        };
    }
};

/// https://tc39.es/ecma262/#prod-BindingElement
pub const BindingElement = union(enum) {
    pub const BindingPatternAndExpression = struct {
        binding_pattern: BindingPattern,
        initializer: ?Expression,
    };

    single_name_binding: SingleNameBinding,
    binding_pattern_and_expression: BindingPatternAndExpression,

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: BindingElement,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // BindingElement : BindingPattern Initializer[opt]
        // 1. Return the BoundNames of BindingPattern.
        switch (self) {
            .single_name_binding => |single_name_binding| try single_name_binding.collectBoundNames(allocator, bound_names),
            .binding_pattern_and_expression => |binding_pattern_and_expression| try binding_pattern_and_expression.binding_pattern.collectBoundNames(allocator, bound_names),
        }
    }

    /// 15.1.2 Static Semantics: ContainsExpression
    /// https://tc39.es/ecma262/#sec-static-semantics-containsexpression
    pub fn containsExpression(self: BindingElement) bool {
        // BindingElement : BindingPattern Initializer
        // 1. Return true.
        // SingleNameBinding : BindingIdentifier
        // 1. Return false.
        // SingleNameBinding : BindingIdentifier Initializer
        // 1. Return true.
        return switch (self) {
            .single_name_binding => |single_name_binding| single_name_binding.initializer != null,
            .binding_pattern_and_expression => |binding_pattern_and_expression| binding_pattern_and_expression.binding_pattern.containsExpression(),
        };
    }

    /// 15.1.3 Static Semantics: IsSimpleParameterList
    /// https://tc39.es/ecma262/#sec-static-semantics-issimpleparameterlist
    pub fn isSimpleParameterList(self: BindingElement) bool {
        // BindingElement : BindingPattern
        // 1. Return false.
        // BindingElement : BindingPattern Initializer
        // 1. Return false.
        // SingleNameBinding : BindingIdentifier
        // 1. Return true.
        // SingleNameBinding : BindingIdentifier Initializer
        // 1. Return false.
        return self == .single_name_binding and self.single_name_binding.initializer == null;
    }
};

/// https://tc39.es/ecma262/#prod-SingleNameBinding
pub const SingleNameBinding = struct {
    binding_identifier: Identifier,
    initializer: ?Expression,

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: SingleNameBinding,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // SingleNameBinding : BindingIdentifier Initializer[opt]
        // 1. Return the BoundNames of BindingIdentifier.
        try bound_names.append(allocator, self.binding_identifier);
    }
};

/// https://tc39.es/ecma262/#prod-BindingRestElement
pub const BindingRestElement = union(enum) {
    binding_identifier: Identifier,
    binding_pattern: BindingPattern,

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: BindingRestElement,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        switch (self) {
            .binding_identifier => |binding_identifier| try bound_names.append(allocator, binding_identifier),
            .binding_pattern => |binding_pattern| try binding_pattern.collectBoundNames(allocator, bound_names),
        }
    }

    /// 15.1.2 Static Semantics: ContainsExpression
    /// https://tc39.es/ecma262/#sec-static-semantics-containsexpression
    pub fn containsExpression(self: BindingRestElement) bool {
        // BindingRestElement : ... BindingIdentifier
        // 1. Return false.
        // BindingRestElement : ... BindingPattern
        // 1. Return ContainsExpression of BindingPattern.
        return switch (self) {
            .binding_identifier => false,
            .binding_pattern => |binding_pattern| binding_pattern.containsExpression(),
        };
    }
};

/// https://tc39.es/ecma262/#prod-ExpressionStatement
pub const ExpressionStatement = struct {
    expression: Expression,
};

/// https://tc39.es/ecma262/#prod-IfStatement
pub const IfStatement = struct {
    test_expression: Expression,
    consequent_statement: *Statement,
    alternate_statement: ?*Statement,

    /// 8.2.8 Static Semantics: VarDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-vardeclarednames
    pub fn collectVarDeclaredNames(
        self: IfStatement,
        allocator: std.mem.Allocator,
        var_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // IfStatement : if ( Expression ) Statement
        // 1. Return the VarDeclaredNames of Statement.
        // IfStatement : if ( Expression ) Statement else Statement
        // 1. Let names1 be the VarDeclaredNames of the first Statement.
        // 2. Let names2 be the VarDeclaredNames of the second Statement.
        // 3. Return the list-concatenation of names1 and names2.
        try self.consequent_statement.collectVarDeclaredNames(allocator, var_declared_names);
        if (self.alternate_statement) |alternate_statement| {
            try alternate_statement.collectVarDeclaredNames(allocator, var_declared_names);
        }
    }

    /// 8.2.9 Static Semantics: VarScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-varscopeddeclarations
    pub fn collectVarScopedDeclarations(
        self: IfStatement,
        allocator: std.mem.Allocator,
        var_scoped_declarations: *std.ArrayList(VarScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // IfStatement : if ( Expression ) Statement
        // 1. Return the VarScopedDeclarations of Statement.
        // IfStatement : if ( Expression ) Statement else Statement
        // 1. Let decls1 be the VarScopedDeclarations of the first Statement.
        // 2. Let decls2 be the VarScopedDeclarations of the second Statement.
        // 3. Return the list-concatenation of decls1 and decls2.
        try self.consequent_statement.collectVarScopedDeclarations(allocator, var_scoped_declarations);
        if (self.alternate_statement) |alternate_statement| {
            try alternate_statement.collectVarScopedDeclarations(allocator, var_scoped_declarations);
        }
    }
};

/// https://tc39.es/ecma262/#prod-IterationStatement
pub const IterationStatement = union(enum) {
    do_while_statement: DoWhileStatement,
    while_statement: WhileStatement,
    for_statement: ForStatement,
    for_in_of_statement: ForInOfStatement,
};

/// https://tc39.es/ecma262/#prod-DoWhileStatement
pub const DoWhileStatement = struct {
    test_expression: Expression,
    consequent_statement: *Statement,

    /// 8.2.8 Static Semantics: VarDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-vardeclarednames
    pub fn collectVarDeclaredNames(
        self: DoWhileStatement,
        allocator: std.mem.Allocator,
        var_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // DoWhileStatement : do Statement while ( Expression ) ;
        // 1. Return the VarDeclaredNames of Statement.
        try self.consequent_statement.collectVarDeclaredNames(allocator, var_declared_names);
    }

    /// 8.2.9 Static Semantics: VarScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-varscopeddeclarations
    pub fn collectVarScopedDeclarations(
        self: DoWhileStatement,
        allocator: std.mem.Allocator,
        var_scoped_declarations: *std.ArrayList(VarScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // DoWhileStatement : do Statement while ( Expression ) ;
        // 1. Return the VarScopedDeclarations of Statement.
        try self.consequent_statement.collectVarScopedDeclarations(allocator, var_scoped_declarations);
    }
};

/// https://tc39.es/ecma262/#prod-WhileStatement
pub const WhileStatement = struct {
    test_expression: Expression,
    consequent_statement: *Statement,

    /// 8.2.8 Static Semantics: VarDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-vardeclarednames
    pub fn collectVarDeclaredNames(
        self: WhileStatement,
        allocator: std.mem.Allocator,
        var_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // WhileStatement : while ( Expression ) Statement
        // 1. Return the VarDeclaredNames of Statement.
        try self.consequent_statement.collectVarDeclaredNames(allocator, var_declared_names);
    }

    /// 8.2.9 Static Semantics: VarScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-varscopeddeclarations
    pub fn collectVarScopedDeclarations(
        self: WhileStatement,
        allocator: std.mem.Allocator,
        var_scoped_declarations: *std.ArrayList(VarScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // WhileStatement : while ( Expression ) Statement
        // 1. Return the VarScopedDeclarations of Statement.
        try self.consequent_statement.collectVarScopedDeclarations(allocator, var_scoped_declarations);
    }
};

/// https://tc39.es/ecma262/#prod-ForStatement
pub const ForStatement = struct {
    pub const Initializer = union(enum) {
        expression: Expression,
        variable_statement: VariableStatement,
        lexical_declaration: LexicalDeclaration,
    };

    initializer: ?Initializer,
    test_expression: ?Expression,
    increment_expression: ?Expression,
    consequent_statement: *Statement,

    /// 8.2.8 Static Semantics: VarDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-vardeclarednames
    pub fn collectVarDeclaredNames(
        self: ForStatement,
        allocator: std.mem.Allocator,
        var_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // ForStatement : for ( var VariableDeclarationList ; Expression[opt] ; Expression[opt] ) Statement
        // 1. Let names1 be the BoundNames of VariableDeclarationList.
        // 2. Let names2 be the VarDeclaredNames of Statement.
        // 3. Return the list-concatenation of names1 and names2.
        // ForStatement : for ( Expression[opt] ; Expression[opt] ; Expression[opt] ) Statement
        // 1. Return the VarDeclaredNames of Statement.
        // ForStatement : for ( LexicalDeclaration Expression[opt] ; Expression[opt] ) Statement
        // 1. Return the VarDeclaredNames of Statement.
        if (self.initializer) |initializer| switch (initializer) {
            .variable_statement => {
                try self.initializer.?.variable_statement.variable_declaration_list.collectBoundNames(allocator, var_declared_names);
            },
            else => {},
        };
        try self.consequent_statement.collectVarDeclaredNames(allocator, var_declared_names);
    }

    /// 8.2.9 Static Semantics: VarScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-varscopeddeclarations
    pub fn collectVarScopedDeclarations(
        self: ForStatement,
        allocator: std.mem.Allocator,
        var_scoped_declarations: *std.ArrayList(VarScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // ForStatement : for ( var VariableDeclarationList ; Expression[opt] ; Expression[opt] ) Statement
        // 1. Let decls1 be the VarScopedDeclarations of VariableDeclarationList.
        // 2. Let decls2 be the VarScopedDeclarations of Statement.
        // 3. Return the list-concatenation of decls1 and decls2.
        // ForStatement : for ( Expression[opt] ; Expression[opt] ; Expression[opt] ) Statement
        // 1. Return the VarScopedDeclarations of Statement.
        // ForStatement : for ( LexicalDeclaration Expression[opt] ; Expression[opt] ) Statement
        // 1. Return the VarScopedDeclarations of Statement.
        if (self.initializer) |initializer| switch (initializer) {
            .variable_statement => {
                try self.initializer.?.variable_statement.variable_declaration_list.collectVarScopedDeclarations(allocator, var_scoped_declarations);
            },
            else => {},
        };
        try self.consequent_statement.collectVarScopedDeclarations(allocator, var_scoped_declarations);
    }
};

/// https://tc39.es/ecma262/#prod-ForInOfStatement
pub const ForInOfStatement = struct {
    pub const Type = enum {
        in,
        of,
        async_of,
    };

    pub const Initializer = union(enum) {
        expression: Expression,
        for_binding: ForBinding,
        for_declaration: ForDeclaration,
    };

    type: Type,
    initializer: Initializer,
    expression: Expression,
    consequent_statement: *Statement,

    /// 8.2.8 Static Semantics: VarDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-vardeclarednames
    pub fn collectVarDeclaredNames(
        self: ForInOfStatement,
        allocator: std.mem.Allocator,
        var_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // ForInOfStatement :
        //     for ( LeftHandSideExpression in Expression ) Statement
        //     for ( ForDeclaration in Expression ) Statement
        //     for ( LeftHandSideExpression of AssignmentExpression ) Statement
        //     for ( ForDeclaration of AssignmentExpression ) Statement
        //     for await ( LeftHandSideExpression of AssignmentExpression ) Statement
        //     for await ( ForDeclaration of AssignmentExpression ) Statement
        if (self.initializer != .for_binding) {
            // 1. Return the VarDeclaredNames of Statement.
            try self.consequent_statement.collectVarDeclaredNames(allocator, var_declared_names);
        }
        // ForInOfStatement :
        //     for ( var ForBinding in Expression ) Statement
        //     for ( var ForBinding of AssignmentExpression ) Statement
        //     for await ( var ForBinding of AssignmentExpression ) Statement
        else {
            // 1. Let names1 be the BoundNames of ForBinding.
            // 2. Let names2 be the VarDeclaredNames of Statement.
            // 3. Return the list-concatenation of names1 and names2.
            try self.initializer.for_binding.collectBoundNames(allocator, var_declared_names);
            try self.consequent_statement.collectVarDeclaredNames(allocator, var_declared_names);
        }
    }

    /// 8.2.9 Static Semantics: VarScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-varscopeddeclarations
    pub fn collectVarScopedDeclarations(
        self: ForInOfStatement,
        allocator: std.mem.Allocator,
        var_scoped_declarations: *std.ArrayList(VarScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // ForInOfStatement :
        //     for ( LeftHandSideExpression in Expression ) Statement
        //     for ( ForDeclaration in Expression ) Statement
        //     for ( LeftHandSideExpression of AssignmentExpression ) Statement
        //     for ( ForDeclaration of AssignmentExpression ) Statement
        //     for await ( LeftHandSideExpression of AssignmentExpression ) Statement
        //     for await ( ForDeclaration of AssignmentExpression ) Statement
        if (self.initializer != .for_binding) {
            // 1. Return the VarScopedDeclarations of Statement.
            try self.consequent_statement.collectVarScopedDeclarations(allocator, var_scoped_declarations);
        }
        // ForInOfStatement :
        //     for ( var ForBinding in Expression ) Statement
        //     for ( var ForBinding of AssignmentExpression ) Statement
        //     for await ( var ForBinding of AssignmentExpression ) Statement
        else {
            // 1. Let decls1 be « ForBinding ».
            // 2. Let decls2 be the VarScopedDeclarations of Statement.
            // 3. Return the list-concatenation of decls1 and decls2.
            try var_scoped_declarations.append(allocator, .{
                .variable_declaration = switch (self.initializer.for_binding) {
                    .binding_identifier => |binding_identifier| .{
                        .binding_identifier = .{
                            .binding_identifier = binding_identifier,
                            .initializer = null,
                        },
                    },
                    .binding_pattern => |binding_pattern| .{
                        .binding_pattern = .{
                            .binding_pattern = binding_pattern,
                            .initializer = undefined, // Not relevant here
                        },
                    },
                },
            });
            try self.consequent_statement.collectVarScopedDeclarations(allocator, var_scoped_declarations);
        }
    }
};

/// https://tc39.es/ecma262/#prod-ForDeclaration
pub const ForDeclaration = struct {
    type: LexicalDeclaration.Type,
    for_binding: ForBinding,
};

/// https://tc39.es/ecma262/#prod-ForBinding
pub const ForBinding = union(enum) {
    binding_identifier: Identifier,
    binding_pattern: BindingPattern,

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: ForBinding,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        switch (self) {
            .binding_identifier => |binding_identifier| try bound_names.append(allocator, binding_identifier),
            .binding_pattern => |binding_pattern| try binding_pattern.collectBoundNames(allocator, bound_names),
        }
    }
};

/// https://tc39.es/ecma262/#prod-ContinueStatement
pub const ContinueStatement = struct {
    label: ?Identifier,
};

/// https://tc39.es/ecma262/#prod-BreakStatement
pub const BreakStatement = struct {
    label: ?Identifier,
};

/// https://tc39.es/ecma262/#prod-ReturnStatement
pub const ReturnStatement = struct {
    expression: ?Expression,
};

/// https://tc39.es/ecma262/#prod-WithStatement
pub const WithStatement = struct {
    expression: Expression,
    statement: *Statement,

    /// 8.2.8 Static Semantics: VarDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-vardeclarednames
    pub fn collectVarDeclaredNames(
        self: WithStatement,
        allocator: std.mem.Allocator,
        var_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // WithStatement : with ( Expression ) Statement
        // 1. Return the VarDeclaredNames of Statement.
        try self.statement.collectVarDeclaredNames(allocator, var_declared_names);
    }

    /// 8.2.9 Static Semantics: VarScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-varscopeddeclarations
    pub fn collectVarScopedDeclarations(
        self: WithStatement,
        allocator: std.mem.Allocator,
        var_scoped_declarations: *std.ArrayList(VarScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // WithStatement : with ( Expression ) Statement
        // 1. Return the VarScopedDeclarations of Statement.
        try self.statement.collectVarScopedDeclarations(allocator, var_scoped_declarations);
    }
};

/// https://tc39.es/ecma262/#prod-SwitchStatement
pub const SwitchStatement = struct {
    expression: Expression,
    case_block: CaseBlock,

    /// 8.2.8 Static Semantics: VarDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-vardeclarednames
    pub fn collectVarDeclaredNames(
        self: SwitchStatement,
        allocator: std.mem.Allocator,
        var_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // SwitchStatement : switch ( Expression ) CaseBlock
        // 1. Return the VarDeclaredNames of CaseBlock.
        try self.case_block.collectVarDeclaredNames(allocator, var_declared_names);
    }

    /// 8.2.9 Static Semantics: VarScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-varscopeddeclarations
    pub fn collectVarScopedDeclarations(
        self: SwitchStatement,
        allocator: std.mem.Allocator,
        var_scoped_declarations: *std.ArrayList(VarScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // SwitchStatement : switch ( Expression ) CaseBlock
        // 1. Return the VarScopedDeclarations of CaseBlock.
        try self.case_block.collectVarScopedDeclarations(allocator, var_scoped_declarations);
    }
};

/// https://tc39.es/ecma262/#prod-CaseBlock
pub const CaseBlock = struct {
    pub const Item = union(enum) {
        case_clause: CaseClause,
        default_clause: DefaultClause,
    };

    items: []const Item,

    /// 8.2.6 Static Semantics: LexicallyDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-lexicallydeclarednames
    pub fn collectLexicallyDeclaredNames(
        self: CaseBlock,
        allocator: std.mem.Allocator,
        lexically_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // CaseBlock : { }
        // 1. Return a new empty List.
        // CaseBlock : { CaseClauses[opt] DefaultClause CaseClauses[opt] }
        // 1. If the first CaseClauses is present, let names1 be the LexicallyDeclaredNames of the
        //    first CaseClauses.
        // 2. Else, let names1 be a new empty List.
        // 3. Let names2 be the LexicallyDeclaredNames of DefaultClause.
        // 4. If the second CaseClauses is present, let names3 be the LexicallyDeclaredNames of the
        //    second CaseClauses.
        // 5. Else, let names3 be a new empty List.
        // 6. Return the list-concatenation of names1, names2, and names3.
        // CaseClauses : CaseClauses CaseClause
        // 1. Let names1 be the LexicallyDeclaredNames of CaseClauses.
        // 2. Let names2 be the LexicallyDeclaredNames of CaseClause.
        // 3. Return the list-concatenation of names1 and names2.
        for (self.items) |item| switch (item) {
            inline else => |node| try node.collectLexicallyDeclaredNames(allocator, lexically_declared_names),
        };
    }

    /// 8.2.7 Static Semantics: LexicallyScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-lexicallyscopeddeclarations
    pub fn collectLexicallyScopedDeclarations(
        self: CaseBlock,
        allocator: std.mem.Allocator,
        lexically_scoped_declarations: *std.ArrayList(LexicallyScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // CaseBlock : { }
        // 1. Return a new empty List.
        // CaseBlock : { CaseClauses[opt] DefaultClause CaseClauses[opt] }
        // 1. If the first CaseClauses is present, let decls1 be the LexicallyScopedDeclarations of
        //    the first CaseClauses.
        // 2. Else, let decls1 be a new empty List.
        // 3. Let decls2 be the LexicallyScopedDeclarations of DefaultClause.
        // 4. If the second CaseClauses is present, let decls3 be the LexicallyScopedDeclarations of
        //    the second CaseClauses.
        // 5. Else, let decls3 be a new empty List.
        // 6. Return the list-concatenation of decls1, decls2, and decls3.
        // CaseClauses : CaseClauses CaseClause
        // 1. Let decls1 be the LexicallyScopedDeclarations of CaseClauses.
        // 2. Let decls2 be the LexicallyScopedDeclarations of CaseClause.
        // 3. Return the list-concatenation of decls1 and decls2.
        for (self.items) |item| switch (item) {
            inline else => |node| try node.collectLexicallyScopedDeclarations(allocator, lexically_scoped_declarations),
        };
    }

    /// 8.2.8 Static Semantics: VarDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-vardeclarednames
    pub fn collectVarDeclaredNames(
        self: CaseBlock,
        allocator: std.mem.Allocator,
        var_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // CaseBlock : { }
        // 1. Return a new empty List.
        // CaseBlock : { CaseClauses[opt] DefaultClause CaseClauses[opt] }
        // 1. If the first CaseClauses is present, let names1 be the VarDeclaredNames of the first
        //    CaseClauses.
        // 2. Else, let names1 be a new empty List.
        // 3. Let names2 be the VarDeclaredNames of DefaultClause.
        // 4. If the second CaseClauses is present, let names3 be the VarDeclaredNames of the second
        //    CaseClauses.
        // 5. Else, let names3 be a new empty List.
        // 6. Return the list-concatenation of names1, names2, and names3.
        // CaseClauses : CaseClauses CaseClause
        // 1. Let names1 be the VarDeclaredNames of CaseClauses.
        // 2. Let names2 be the VarDeclaredNames of CaseClause.
        // 3. Return the list-concatenation of names1 and names2.
        for (self.items) |item| switch (item) {
            inline else => |node| try node.collectVarDeclaredNames(allocator, var_declared_names),
        };
    }

    /// 8.2.9 Static Semantics: VarScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-varscopeddeclarations
    pub fn collectVarScopedDeclarations(
        self: CaseBlock,
        allocator: std.mem.Allocator,
        var_scoped_declarations: *std.ArrayList(VarScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // CaseBlock : { }
        // 1. Return a new empty List.
        // CaseBlock : { CaseClauses[opt] DefaultClause CaseClauses[opt] }
        // 1. If the first CaseClauses is present, let decls1 be the VarScopedDeclarations of the
        //    first CaseClauses.
        // 2. Else, let decls1 be a new empty List.
        // 3. Let decls2 be the VarScopedDeclarations of DefaultClause.
        // 4. If the second CaseClauses is present, let decls3 be the VarScopedDeclarations of the
        //    second CaseClauses.
        // 5. Else, let decls3 be a new empty List.
        // 6. Return the list-concatenation of decls1, decls2, and decls3.
        // CaseClauses : CaseClauses CaseClause
        // 1. Let decls1 be the VarScopedDeclarations of CaseClauses.
        // 2. Let decls2 be the VarScopedDeclarations of CaseClause.
        // 3. Return the list-concatenation of decls1 and decls2.
        for (self.items) |item| switch (item) {
            inline else => |node| try node.collectVarScopedDeclarations(allocator, var_scoped_declarations),
        };
    }
};

/// https://tc39.es/ecma262/#prod-CaseClause
pub const CaseClause = struct {
    expression: Expression,
    statement_list: StatementList,

    /// 8.2.6 Static Semantics: LexicallyDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-lexicallydeclarednames
    pub fn collectLexicallyDeclaredNames(
        self: CaseClause,
        allocator: std.mem.Allocator,
        lexically_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // CaseClause : case Expression : StatementListopt
        // 1. If the StatementList is present, return the LexicallyDeclaredNames of StatementList.
        // 2. Return a new empty List.
        try self.statement_list.collectLexicallyDeclaredNames(allocator, lexically_declared_names);
    }

    /// 8.2.7 Static Semantics: LexicallyScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-lexicallyscopeddeclarations
    pub fn collectLexicallyScopedDeclarations(
        self: CaseClause,
        allocator: std.mem.Allocator,
        lexically_scoped_declarations: *std.ArrayList(LexicallyScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // CaseClause : case Expression : StatementList[opt]
        // 1. If the StatementList is present, return the LexicallyScopedDeclarations of
        //    StatementList.
        // 2. Return a new empty List.
        try self.statement_list.collectLexicallyScopedDeclarations(allocator, lexically_scoped_declarations);
    }

    /// 8.2.8 Static Semantics: VarDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-vardeclarednames
    pub fn collectVarDeclaredNames(
        self: CaseClause,
        allocator: std.mem.Allocator,
        var_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // CaseClause : case Expression : StatementList[opt]
        // 1. If the StatementList is present, return the VarDeclaredNames of StatementList.
        // 2. Return a new empty List.
        try self.statement_list.collectVarDeclaredNames(allocator, var_declared_names);
    }

    /// 8.2.9 Static Semantics: VarScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-varscopeddeclarations
    pub fn collectVarScopedDeclarations(
        self: CaseClause,
        allocator: std.mem.Allocator,
        var_scoped_declarations: *std.ArrayList(VarScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // CaseClause : case Expression : StatementList[opt]
        // 1. If the StatementList is present, return the VarScopedDeclarations of StatementList.
        // 2. Return a new empty List.
        try self.statement_list.collectVarScopedDeclarations(allocator, var_scoped_declarations);
    }
};

/// https://tc39.es/ecma262/#prod-DefaultClause
pub const DefaultClause = struct {
    statement_list: StatementList,

    /// 8.2.6 Static Semantics: LexicallyDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-lexicallydeclarednames
    pub fn collectLexicallyDeclaredNames(
        self: DefaultClause,
        allocator: std.mem.Allocator,
        lexically_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // DefaultClause : default : StatementListopt
        // 1. If the StatementList is present, return the LexicallyDeclaredNames of StatementList.
        // 2. Return a new empty List.
        try self.statement_list.collectLexicallyDeclaredNames(allocator, lexically_declared_names);
    }

    /// 8.2.7 Static Semantics: LexicallyScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-lexicallyscopeddeclarations
    pub fn collectLexicallyScopedDeclarations(
        self: DefaultClause,
        allocator: std.mem.Allocator,
        lexically_scoped_declarations: *std.ArrayList(LexicallyScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // DefaultClause : default : StatementList[opt]
        // 1. If the StatementList is present, return the LexicallyScopedDeclarations of
        //    StatementList.
        // 2. Return a new empty List.
        try self.statement_list.collectLexicallyScopedDeclarations(allocator, lexically_scoped_declarations);
    }

    /// 8.2.8 Static Semantics: VarDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-vardeclarednames
    pub fn collectVarDeclaredNames(
        self: DefaultClause,
        allocator: std.mem.Allocator,
        var_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // DefaultClause : default : StatementList[opt]
        // 1. If the StatementList is present, return the VarDeclaredNames of StatementList.
        // 2. Return a new empty List.
        try self.statement_list.collectVarDeclaredNames(allocator, var_declared_names);
    }

    /// 8.2.9 Static Semantics: VarScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-varscopeddeclarations
    pub fn collectVarScopedDeclarations(
        self: DefaultClause,
        allocator: std.mem.Allocator,
        var_scoped_declarations: *std.ArrayList(VarScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // DefaultClause : default : StatementList[opt]
        // 1. If the StatementList is present, return the VarScopedDeclarations of StatementList.
        // 2. Return a new empty List.
        try self.statement_list.collectVarScopedDeclarations(allocator, var_scoped_declarations);
    }
};

/// https://tc39.es/ecma262/#prod-LabelledStatement
pub const LabelledStatement = struct {
    pub const LabelledItem = union(enum) {
        statement: *Statement,
        function_declaration: FunctionDeclaration,
    };

    label_identifier: Identifier,
    labelled_item: LabelledItem,

    pub fn hasLexicallyScopedDeclarations(self: LabelledStatement) bool {
        return switch (self.labelled_item) {
            .statement => false,
            .function_declaration => true,
        };
    }

    /// 8.2.6 Static Semantics: LexicallyDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-lexicallydeclarednames
    pub fn collectLexicallyDeclaredNames(
        self: LabelledStatement,
        allocator: std.mem.Allocator,
        lexically_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // LabelledStatement : LabelIdentifier : LabelledItem
        // 1. Return the LexicallyDeclaredNames of LabelledItem.
        switch (self.labelled_item) {
            // LabelledItem : Statement
            .statement => {
                // 1. Return a new empty List.
            },

            // LabelledItem : FunctionDeclaration
            .function_declaration => |function_declaration| {
                // 1. Return the BoundNames of FunctionDeclaration.
                try function_declaration.collectBoundNames(allocator, lexically_declared_names);
            },
        }
    }

    /// 8.2.7 Static Semantics: LexicallyScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-lexicallyscopeddeclarations
    pub fn collectLexicallyScopedDeclarations(
        self: LabelledStatement,
        allocator: std.mem.Allocator,
        lexically_scoped_declarations: *std.ArrayList(LexicallyScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        //  LabelledStatement : LabelIdentifier : LabelledItem
        // 1. Return the LexicallyScopedDeclarations of LabelledItem.
        switch (self.labelled_item) {
            // LabelledItem : Statement
            .statement => {
                // 1. Return a new empty List.
            },

            // LabelledItem : FunctionDeclaration
            .function_declaration => |function_declaration| {
                // 1. Return « FunctionDeclaration ».
                try lexically_scoped_declarations.append(allocator, .{
                    .hoistable_declaration = .{ .function_declaration = function_declaration },
                });
            },
        }
    }

    /// 8.2.8 Static Semantics: VarDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-vardeclarednames
    pub fn collectVarDeclaredNames(
        self: LabelledStatement,
        allocator: std.mem.Allocator,
        var_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        switch (self.labelled_item) {
            // LabelledStatement : LabelIdentifier : LabelledItem
            .statement => |statement| {
                // 1. Return the VarDeclaredNames of LabelledItem.
                try statement.collectVarDeclaredNames(allocator, var_declared_names);
            },

            // LabelledItem : FunctionDeclaration
            .function_declaration => {
                // 1. Return a new empty List.
            },
        }
    }

    /// 8.2.9 Static Semantics: VarScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-varscopeddeclarations
    pub fn collectVarScopedDeclarations(
        self: LabelledStatement,
        allocator: std.mem.Allocator,
        var_scoped_declarations: *std.ArrayList(VarScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        switch (self.labelled_item) {
            //  LabelledStatement : LabelIdentifier : LabelledItem
            .statement => |statement| {
                // 1. Return the VarScopedDeclarations of LabelledItem.
                try statement.collectVarScopedDeclarations(allocator, var_scoped_declarations);
            },

            // LabelledItem : FunctionDeclaration
            .function_declaration => {
                // 1. Return a new empty List.
            },
        }
    }

    /// 8.2.12 Static Semantics: TopLevelVarDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-toplevelvardeclarednames
    pub fn collectTopLevelVarDeclaredNames(
        self: LabelledStatement,
        allocator: std.mem.Allocator,
        var_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // LabelledStatement : LabelIdentifier : LabelledItem
        // 1. Return the TopLevelVarDeclaredNames of LabelledItem.
        switch (self.labelled_item) {
            // LabelledItem : Statement
            .statement => |statement| {
                // 1. If Statement is Statement : LabelledStatement , return the
                //    TopLevelVarDeclaredNames of Statement.
                if (statement.* == .labelled_statement) {
                    try statement.labelled_statement.collectTopLevelVarDeclaredNames(allocator, var_declared_names);
                }
                // 2. Return the VarDeclaredNames of Statement.
                else {
                    try statement.collectVarDeclaredNames(allocator, var_declared_names);
                }
            },

            // LabelledItem : FunctionDeclaration
            .function_declaration => |function_declaration| {
                // 1. Return the BoundNames of FunctionDeclaration.
                try function_declaration.collectBoundNames(allocator, var_declared_names);
            },
        }
    }

    /// 8.2.13 Static Semantics: TopLevelVarScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-toplevelvarscopeddeclarations
    pub fn collectTopLevelVarScopedDeclarations(
        self: LabelledStatement,
        allocator: std.mem.Allocator,
        var_scoped_declarations: *std.ArrayList(VarScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // LabelledStatement : LabelIdentifier : LabelledItem
        // 1. Return the TopLevelVarScopedDeclarations of LabelledItem.
        switch (self.labelled_item) {
            // LabelledItem : Statement
            .statement => |statement| {
                // 1. If Statement is Statement : LabelledStatement , return the
                //    TopLevelVarScopedDeclarations of Statement.
                if (statement.* == .labelled_statement) {
                    try statement.labelled_statement.collectTopLevelVarScopedDeclarations(allocator, var_scoped_declarations);
                }
                // 2. Return the VarScopedDeclarations of Statement.
                else {
                    try statement.collectVarScopedDeclarations(allocator, var_scoped_declarations);
                }
            },

            // LabelledItem : FunctionDeclaration
            .function_declaration => |function_declaration| {
                // 1. Return « FunctionDeclaration ».
                try var_scoped_declarations.append(allocator, .{
                    .hoistable_declaration = .{ .function_declaration = function_declaration },
                });
            },
        }
    }
};

/// https://tc39.es/ecma262/#prod-ThrowStatement
pub const ThrowStatement = struct {
    expression: Expression,
};

/// https://tc39.es/ecma262/#prod-TryStatement
pub const TryStatement = struct {
    try_block: Block,
    catch_parameter: ?CatchParameter,
    catch_block: ?Block,
    finally_block: ?Block,

    /// 8.2.8 Static Semantics: VarDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-vardeclarednames
    pub fn collectVarDeclaredNames(
        self: TryStatement,
        allocator: std.mem.Allocator,
        var_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // TryStatement : try Block Catch
        // 1. Let names1 be the VarDeclaredNames of Block.
        // 2. Let names2 be the VarDeclaredNames of Catch.
        // 3. Return the list-concatenation of names1 and names2.
        // TryStatement : try Block Finally
        // 1. Let names1 be the VarDeclaredNames of Block.
        // 2. Let names2 be the VarDeclaredNames of Finally.
        // 3. Return the list-concatenation of names1 and names2.
        // TryStatement : try Block Catch Finally
        // 1. Let names1 be the VarDeclaredNames of Block.
        // 2. Let names2 be the VarDeclaredNames of Catch.
        // 3. Let names3 be the VarDeclaredNames of Finally.
        // 4. Return the list-concatenation of names1, names2, and names3.
        // Catch : catch ( CatchParameter ) Block
        // 1. Return the VarDeclaredNames of Block.
        try self.try_block.statement_list.collectVarDeclaredNames(allocator, var_declared_names);
        if (self.catch_block) |catch_block| {
            try catch_block.statement_list.collectVarDeclaredNames(allocator, var_declared_names);
        }
        if (self.finally_block) |finally_block| {
            try finally_block.statement_list.collectVarDeclaredNames(allocator, var_declared_names);
        }
    }

    /// 8.2.9 Static Semantics: VarScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-varscopeddeclarations
    pub fn collectVarScopedDeclarations(
        self: TryStatement,
        allocator: std.mem.Allocator,
        var_scoped_declarations: *std.ArrayList(VarScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // TryStatement : try Block Catch
        // 1. Let decls1 be the VarScopedDeclarations of Block.
        // 2. Let decls2 be the VarScopedDeclarations of Catch.
        // 3. Return the list-concatenation of decls1 and decls2.
        // TryStatement : try Block Finally
        // 1. Let decls1 be the VarScopedDeclarations of Block.
        // 2. Let decls2 be the VarScopedDeclarations of Finally.
        // 3. Return the list-concatenation of decls1 and decls2.
        // TryStatement : try Block Catch Finally
        // 1. Let decls1 be the VarScopedDeclarations of Block.
        // 2. Let decls2 be the VarScopedDeclarations of Catch.
        // 3. Let decls3 be the VarScopedDeclarations of Finally.
        // 4. Return the list-concatenation of decls1, decls2, and decls3.
        // Catch : catch ( CatchParameter ) Block
        // 1. Return the VarScopedDeclarations of Block.
        try self.try_block.statement_list.collectVarScopedDeclarations(allocator, var_scoped_declarations);
        if (self.catch_block) |catch_block| {
            try catch_block.statement_list.collectVarScopedDeclarations(allocator, var_scoped_declarations);
        }
        if (self.finally_block) |finally_block| {
            try finally_block.statement_list.collectVarScopedDeclarations(allocator, var_scoped_declarations);
        }
    }
};

/// https://tc39.es/ecma262/#prod-CatchParameter
pub const CatchParameter = union(enum) {
    binding_identifier: Identifier,
    binding_pattern: BindingPattern,

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: CatchParameter,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        switch (self) {
            .binding_identifier => |binding_identifier| try bound_names.append(allocator, binding_identifier),
            .binding_pattern => |binding_pattern| try binding_pattern.collectBoundNames(allocator, bound_names),
        }
    }
};

/// https://tc39.es/ecma262/#prod-FormalParameters
pub const FormalParameters = struct {
    pub const Item = union(enum) {
        formal_parameter: FormalParameter,
        function_rest_parameter: FunctionRestParameter,
    };

    items: []const Item,
    arguments_object_needed: bool,

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: FormalParameters,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // FormalParameterList : FormalParameterList , FormalParameter
        // 1. Let names1 be the BoundNames of FormalParameterList.
        // 2. Let names2 be the BoundNames of FormalParameter.
        // 3. Return the list-concatenation of names1 and names2.
        for (self.items) |item| switch (item) {
            .formal_parameter => |formal_parameter| try formal_parameter.binding_element.collectBoundNames(allocator, bound_names),
            .function_rest_parameter => |function_rest_parameter| try function_rest_parameter.binding_rest_element.collectBoundNames(allocator, bound_names),
        };
    }

    /// 15.1.2 Static Semantics: ContainsExpression
    /// https://tc39.es/ecma262/#sec-static-semantics-containsexpression
    pub fn containsExpression(self: FormalParameters) bool {
        // FormalParameters : [empty]
        // 1. Return false.
        // FormalParameters : FormalParameterList , FunctionRestParameter
        // 1. If ContainsExpression of FormalParameterList is true, return true.
        // 2. Return ContainsExpression of FunctionRestParameter.
        // FormalParameterList : FormalParameterList , FormalParameter
        // 1. If ContainsExpression of FormalParameterList is true, return true.
        // 2. Return ContainsExpression of FormalParameter.
        for (self.items) |item| switch (item) {
            .formal_parameter => |formal_parameter| {
                if (formal_parameter.binding_element.containsExpression()) return true;
            },
            .function_rest_parameter => |function_rest_parameter| {
                if (function_rest_parameter.binding_rest_element.containsExpression()) return true;
            },
        };
        return false;
    }

    /// 15.1.3 Static Semantics: IsSimpleParameterList
    /// https://tc39.es/ecma262/#sec-static-semantics-issimpleparameterlist
    pub fn isSimpleParameterList(self: FormalParameters) bool {
        // FormalParameters : [empty]
        // 1. Return true.
        // FormalParameters : FunctionRestParameter
        // 1. Return false.
        // FormalParameters : FormalParameterList , FunctionRestParameter
        // 1. Return false.
        // FormalParameterList : FormalParameterList , FormalParameter
        // 1. If IsSimpleParameterList of FormalParameterList is false, return false.
        // 2. Return IsSimpleParameterList of FormalParameter.
        for (self.items) |item| switch (item) {
            .formal_parameter => |formal_parameter| {
                //  FormalParameter : BindingElement
                // 1. Return IsSimpleParameterList of BindingElement.
                if (!formal_parameter.binding_element.isSimpleParameterList()) return false;
            },
            .function_rest_parameter => return false,
        };
        return true;
    }

    /// 15.1.5 Static Semantics: ExpectedArgumentCount
    /// https://tc39.es/ecma262/#sec-static-semantics-expectedargumentcount
    pub fn expectedArgumentCount(self: FormalParameters) usize {
        var count: usize = 0;
        for (self.items) |item| switch (item) {
            .formal_parameter => |formal_parameter| switch (formal_parameter.binding_element) {
                .single_name_binding => |single_name_binding| {
                    if (single_name_binding.initializer != null) break;
                    count += 1;
                },
                .binding_pattern_and_expression => |binding_pattern_and_expression| {
                    if (binding_pattern_and_expression.initializer != null) break;
                    count += 1;
                },
            },
            .function_rest_parameter => break,
        };

        return count;
    }
};

/// https://tc39.es/ecma262/#prod-FunctionRestParameter
pub const FunctionRestParameter = struct {
    binding_rest_element: BindingRestElement,
};

/// https://tc39.es/ecma262/#prod-FormalParameter
pub const FormalParameter = struct {
    binding_element: BindingElement,
};

/// https://tc39.es/ecma262/#prod-FunctionDeclaration
pub const FunctionDeclaration = struct {
    identifier: ?Identifier,
    formal_parameters: FormalParameters,
    function_body: FunctionBody,
    source_range: SourceRange,

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: FunctionDeclaration,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // FunctionDeclaration : function BindingIdentifier ( FormalParameters ) { FunctionBody }
        // 1. Return the BoundNames of BindingIdentifier.
        // FunctionDeclaration : function ( FormalParameters ) { FunctionBody }
        // 1. Return « "*default*" ».
        try bound_names.append(allocator, self.identifier orelse "*default*");
    }

    /// 8.2.3 Static Semantics: IsConstantDeclaration
    /// https://tc39.es/ecma262/#sec-static-semantics-isconstantdeclaration
    pub fn isConstantDeclaration(_: FunctionDeclaration) bool {
        // FunctionDeclaration :
        //     function BindingIdentifier ( FormalParameters ) { FunctionBody }
        //     function ( FormalParameters ) { FunctionBody }
        // 1. Return false.
        return false;
    }
};

/// https://tc39.es/ecma262/#prod-FunctionExpression
pub const FunctionExpression = struct {
    identifier: ?Identifier,
    formal_parameters: FormalParameters,
    function_body: FunctionBody,
    source_range: SourceRange,
};

/// https://tc39.es/ecma262/#prod-FunctionBody
pub const FunctionBody = struct {
    pub const Type = enum {
        normal,
        generator,
        async,
        async_generator,
    };

    type: Type,
    statement_list: StatementList,
    strict: bool,
    arguments_object_needed: bool,

    /// 8.2.6 Static Semantics: LexicallyDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-lexicallydeclarednames
    pub fn collectLexicallyDeclaredNames(
        self: FunctionBody,
        allocator: std.mem.Allocator,
        lexically_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // FunctionStatementList : [empty]
        // 1. Return a new empty List.
        // FunctionStatementList : StatementList
        // 1. Return the TopLevelLexicallyDeclaredNames of StatementList.
        try self.statement_list.collectTopLevelLexicallyDeclaredNames(allocator, lexically_declared_names);
    }

    /// 8.2.7 Static Semantics: LexicallyScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-lexicallyscopeddeclarations
    pub fn collectLexicallyScopedDeclarations(
        self: FunctionBody,
        allocator: std.mem.Allocator,
        lexically_scoped_declarations: *std.ArrayList(LexicallyScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // FunctionStatementList : [empty]
        // 1. Return a new empty List.
        // FunctionStatementList : StatementList
        // 1. Return the TopLevelLexicallyScopedDeclarations of StatementList.
        try self.statement_list.collectTopLevelLexicallyScopedDeclarations(allocator, lexically_scoped_declarations);
    }

    /// 8.2.8 Static Semantics: VarDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-vardeclarednames
    pub fn collectVarDeclaredNames(
        self: FunctionBody,
        allocator: std.mem.Allocator,
        var_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // FunctionStatementList : [empty]
        // 1. Return a new empty List.
        // FunctionStatementList : StatementList
        // 1. Return the TopLevelVarDeclaredNames of StatementList.
        try self.statement_list.collectTopLevelVarDeclaredNames(allocator, var_declared_names);
    }

    /// 8.2.9 Static Semantics: VarScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-varscopeddeclarations
    pub fn collectVarScopedDeclarations(
        self: FunctionBody,
        allocator: std.mem.Allocator,
        var_scoped_declarations: *std.ArrayList(VarScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // FunctionStatementList : [empty]
        // 1. Return a new empty List.
        // FunctionStatementList : StatementList
        // 1. Return the TopLevelVarScopedDeclarations of StatementList.
        try self.statement_list.collectTopLevelVarScopedDeclarations(allocator, var_scoped_declarations);
    }

    /// 15.2.2 Static Semantics: FunctionBodyContainsUseStrict
    /// https://tc39.es/ecma262/#sec-static-semantics-functionbodycontainsusestrict
    pub fn functionBodyContainsUseStrict(self: FunctionBody) bool {
        // 1. If the Directive Prologue of FunctionBody contains a Use Strict Directive, return
        //    true.
        // 2. Return false.
        return self.statement_list.containsDirective("use strict");
    }
};

/// https://tc39.es/ecma262/#prod-ArrowFunction
pub const ArrowFunction = struct {
    formal_parameters: FormalParameters,
    function_body: FunctionBody,
    source_range: SourceRange,
};

/// https://tc39.es/ecma262/#prod-MethodDefinition
pub const MethodDefinition = struct {
    pub const Type = enum {
        method,
        get,
        set,
        generator,
        async,
        async_generator,
    };

    pub const Method = union(Type) {
        method: FunctionExpression,
        get: FunctionExpression,
        set: FunctionExpression,
        generator: GeneratorExpression,
        async: AsyncFunctionExpression,
        async_generator: AsyncGeneratorExpression,
    };

    class_element_name: ClassElementName,
    method: Method,

    /// 15.4.3 Static Semantics: SpecialMethod
    /// https://tc39.es/ecma262/#sec-static-semantics-specialmethod
    pub fn specialMethod(self: MethodDefinition) bool {
        // MethodDefinition : ClassElementName ( UniqueFormalParameters ) { FunctionBody }
        // 1. Return false.
        // MethodDefinition :
        //     GeneratorMethod
        //     AsyncMethod
        //     AsyncGeneratorMethod
        //     get ClassElementName ( ) { FunctionBody }
        //     set ClassElementName ( PropertySetParameterList ) { FunctionBody }
        // 1. Return true.
        return switch (self.method) {
            .method => false,
            .get, .set, .generator, .async, .async_generator => true,
        };
    }
};

/// https://tc39.es/ecma262/#prod-GeneratorDeclaration
pub const GeneratorDeclaration = struct {
    identifier: ?Identifier,
    formal_parameters: FormalParameters,
    function_body: FunctionBody,
    source_range: SourceRange,

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: GeneratorDeclaration,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // GeneratorDeclaration : function * BindingIdentifier ( FormalParameters ) { GeneratorBody }
        // 1. Return the BoundNames of BindingIdentifier.
        // GeneratorDeclaration : function * ( FormalParameters ) { GeneratorBody }
        // 1. Return « "*default*" ».
        try bound_names.append(allocator, self.identifier orelse "*default*");
    }

    /// 8.2.3 Static Semantics: IsConstantDeclaration
    /// https://tc39.es/ecma262/#sec-static-semantics-isconstantdeclaration
    pub fn isConstantDeclaration(_: GeneratorDeclaration) bool {
        // GeneratorDeclaration :
        //     function * BindingIdentifier ( FormalParameters ) { GeneratorBody }
        //     function * ( FormalParameters ) { GeneratorBody }
        // 1. Return false.
        return false;
    }
};

/// https://tc39.es/ecma262/#prod-GeneratorExpression
pub const GeneratorExpression = struct {
    identifier: ?Identifier,
    formal_parameters: FormalParameters,
    function_body: FunctionBody,
    source_range: SourceRange,
};

pub const YieldExpression = union(enum) {
    none,
    expression: *Expression,
    delegate: *Expression,
};

/// https://tc39.es/ecma262/#prod-AsyncGeneratorDeclaration
pub const AsyncGeneratorDeclaration = struct {
    identifier: ?Identifier,
    formal_parameters: FormalParameters,
    function_body: FunctionBody,
    source_range: SourceRange,

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: AsyncGeneratorDeclaration,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // AsyncGeneratorDeclaration : async function * BindingIdentifier ( FormalParameters ) { AsyncGeneratorBody }
        // 1. Return the BoundNames of BindingIdentifier.
        // AsyncGeneratorDeclaration : async function * ( FormalParameters ) { AsyncGeneratorBody }
        // 1. Return « "*default*" ».
        try bound_names.append(allocator, self.identifier orelse "*default*");
    }

    /// 8.2.3 Static Semantics: IsConstantDeclaration
    /// https://tc39.es/ecma262/#sec-static-semantics-isconstantdeclaration
    pub fn isConstantDeclaration(_: AsyncGeneratorDeclaration) bool {
        // AsyncGeneratorDeclaration :
        //     async function * BindingIdentifier ( FormalParameters ) { AsyncGeneratorBody }
        //     async function * ( FormalParameters ) { AsyncGeneratorBody }
        // 1. Return false.
        return false;
    }
};

/// https://tc39.es/ecma262/#prod-AsyncGeneratorExpression
pub const AsyncGeneratorExpression = struct {
    identifier: ?Identifier,
    formal_parameters: FormalParameters,
    function_body: FunctionBody,
    source_range: SourceRange,
};

/// https://tc39.es/ecma262/#prod-ClassDeclaration
pub const ClassDeclaration = struct {
    identifier: ?Identifier,
    class_tail: ClassTail,
    source_range: SourceRange,

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: ClassDeclaration,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // ClassDeclaration : class BindingIdentifier ClassTail
        // 1. Return the BoundNames of BindingIdentifier.
        // ClassDeclaration : class ClassTail
        // 1. Return « "*default*" ».
        try bound_names.append(allocator, self.identifier orelse "*default*");
    }

    /// 8.2.3 Static Semantics: IsConstantDeclaration
    /// https://tc39.es/ecma262/#sec-static-semantics-isconstantdeclaration
    pub fn isConstantDeclaration(_: ClassDeclaration) bool {
        // ClassDeclaration :
        //     class BindingIdentifier ClassTail
        //     class ClassTail
        // 1. Return false.
        return false;
    }
};

/// https://tc39.es/ecma262/#prod-ClassExpression
pub const ClassExpression = struct {
    identifier: ?Identifier,
    class_tail: ClassTail,
    source_range: SourceRange,
};

/// https://tc39.es/ecma262/#prod-ClassTail
pub const ClassTail = struct {
    class_heritage: ?*Expression,
    class_body: ClassBody,
};

/// https://tc39.es/ecma262/#prod-ClassBody
pub const ClassBody = struct {
    class_element_list: ClassElementList,

    /// 15.7.3 Static Semantics: ConstructorMethod
    /// https://tc39.es/ecma262/#sec-static-semantics-constructormethod
    pub fn constructorMethod(
        self: ClassBody,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!?MethodDefinition {
        // ClassElementList : ClassElement
        // 1. If the ClassElementKind of ClassElement is constructor-method, return ClassElement.
        // 2. Return empty.
        // ClassElementList : ClassElementList ClassElement
        // 1. Let head be the ConstructorMethod of ClassElementList.
        // 2. If head is not empty, return head.
        // 3. If the ClassElementKind of ClassElement is constructor-method, return ClassElement.
        // 4. Return empty.
        for (self.class_element_list.items) |class_element| {
            if (try class_element.classElementKind(allocator) == .constructor_method) {
                return class_element.method_definition;
            }
        }
        return null;
    }

    /// 15.7.5 Static Semantics: NonConstructorElements
    /// https://tc39.es/ecma262/#sec-static-semantics-nonconstructorelements
    pub fn nonConstructorElements(
        self: ClassBody,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error![]const ClassElement {
        // ClassElementList : ClassElement
        // 1. If the ClassElementKind of ClassElement is non-constructor-method, then
        //     a. Return « ClassElement ».
        // 2. Return a new empty List.
        // ClassElementList : ClassElementList ClassElement
        // 1. Let list be the NonConstructorElements of ClassElementList.
        // 2. If the ClassElementKind of ClassElement is non-constructor-method, then
        //     a. Append ClassElement to list.
        // 3. Return list.
        var class_elements = try std.ArrayList(ClassElement).initCapacity(
            allocator,
            self.class_element_list.items.len,
        );
        for (self.class_element_list.items) |class_element| {
            if (try class_element.classElementKind(allocator) == .non_constructor_method) {
                class_elements.appendAssumeCapacity(class_element);
            }
        }
        return class_elements.toOwnedSlice(allocator);
    }

    /// 15.7.8 Static Semantics: PrivateBoundIdentifiers
    /// https://tc39.es/ecma262/#sec-static-semantics-privateboundidentifiers
    pub fn privateBoundIdentifiers(
        self: ClassBody,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error![]const PrivateIdentifier {
        // ClassElementList : ClassElementList ClassElement
        // 1. Let names1 be the PrivateBoundIdentifiers of ClassElementList.
        // 2. Let names2 be the PrivateBoundIdentifiers of ClassElement.
        // 3. Return the list-concatenation of names1 and names2.
        var private_bound_identifiers: std.ArrayList(PrivateIdentifier) = .empty;
        for (self.class_element_list.items) |class_element| {
            switch (class_element) {
                // ClassElement :
                //     ClassStaticBlock
                //     ;
                .class_static_block, .empty_statement => {
                    // 1. Return a new empty List.
                },

                // MethodDefinition :
                //     ClassElementName ( UniqueFormalParameters ) { FunctionBody }
                //     get ClassElementName ( ) { FunctionBody }
                //     set ClassElementName ( PropertySetParameterList ) { FunctionBody }
                // GeneratorMethod :
                //     * ClassElementName ( UniqueFormalParameters ) { GeneratorBody }
                // AsyncMethod :
                //     async ClassElementName ( UniqueFormalParameters ) { AsyncFunctionBody }
                // AsyncGeneratorMethod :
                //     async * ClassElementName ( UniqueFormalParameters ) { AsyncGeneratorBody }
                .method_definition, .static_method_definition => |method_definition| {
                    // 1. Return the PrivateBoundIdentifiers of ClassElementName.
                    switch (method_definition.class_element_name) {
                        // ClassElementName : PrivateIdentifier
                        .private_identifier => |private_identifier| {
                            // 1. Return a List whose sole element is the StringValue of
                            //    PrivateIdentifier.
                            try private_bound_identifiers.append(allocator, private_identifier);
                        },
                        // ClassElementName : PropertyName
                        .property_name => {
                            // 1. Return a new empty List.
                        },
                    }
                },

                // FieldDefinition : ClassElementName Initializer[opt]
                .field_definition, .static_field_definition => |field_definition| {
                    // 1. Return the PrivateBoundIdentifiers of ClassElementName.
                    switch (field_definition.class_element_name) {
                        // ClassElementName : PrivateIdentifier
                        .private_identifier => |private_identifier| {
                            // 1. Return a List whose sole element is the StringValue of
                            //    PrivateIdentifier.
                            try private_bound_identifiers.append(allocator, private_identifier);
                        },
                        // ClassElementName : PropertyName
                        .property_name => {
                            // 1. Return a new empty List.
                        },
                    }
                },
            }
        }
        return private_bound_identifiers.toOwnedSlice(allocator);
    }
};

/// https://tc39.es/ecma262/#prod-ClassElementList
pub const ClassElementList = struct {
    items: []const ClassElement,
};

/// https://tc39.es/ecma262/#prod-ClassElement
pub const ClassElement = union(enum) {
    pub const Kind = enum {
        constructor_method,
        non_constructor_method,
        empty,
    };

    empty_statement,
    method_definition: MethodDefinition,
    static_method_definition: MethodDefinition,
    field_definition: FieldDefinition,
    static_field_definition: FieldDefinition,
    class_static_block: ClassStaticBlock,

    /// 15.7.2 Static Semantics: ClassElementKind
    /// https://tc39.es/ecma262/#sec-static-semantics-classelementkind
    pub fn classElementKind(
        self: ClassElement,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!Kind {
        switch (self) {
            // ClassElement : MethodDefinition
            .method_definition => |method_definition| {
                // 1. If the PropName of MethodDefinition is "constructor", return
                //    constructor-method.
                if (try method_definition.class_element_name.eql(allocator, "constructor")) {
                    return .constructor_method;
                }

                // 2. Return non-constructor-method.
                return .non_constructor_method;
            },

            // ClassElement :
            //     static MethodDefinition
            //     FieldDefinition ;
            //     static FieldDefinition ;
            // ClassElement : ClassStaticBlock
            .static_method_definition,
            .field_definition,
            .static_field_definition,
            .class_static_block,
            => {
                // 1. Return non-constructor-method.
                return .non_constructor_method;
            },

            // ClassElement : ;
            .empty_statement => {
                // 1. Return empty.
                return .empty;
            },
        }
    }

    /// 15.7.4 Static Semantics: IsStatic
    /// https://tc39.es/ecma262/#sec-static-semantics-isstatic
    pub fn isStatic(self: ClassElement) bool {
        switch (self) {
            // ClassElement : MethodDefinition
            // ClassElement : FieldDefinition ;
            // ClassElement : ;
            .method_definition,
            .field_definition,
            .empty_statement,
            => {
                // 1. Return false.
                return false;
            },

            // ClassElement : static MethodDefinition
            // ClassElement : static FieldDefinition ;
            // ClassElement : ClassStaticBlock
            .static_method_definition,
            .static_field_definition,
            .class_static_block,
            => {
                // 1. Return true.
                return true;
            },
        }
    }
};

/// https://tc39.es/ecma262/#prod-FieldDefinition
pub const FieldDefinition = struct {
    class_element_name: ClassElementName,
    initializer: ?Expression,
};

/// https://tc39.es/ecma262/#prod-ClassElementName
pub const ClassElementName = union(enum) {
    property_name: PropertyName,
    private_identifier: PrivateIdentifier,

    pub fn eql(
        self: ClassElementName,
        allocator: std.mem.Allocator,
        comptime name: []const u8,
    ) std.mem.Allocator.Error!bool {
        return switch (self) {
            .property_name => |property_name| property_name.eql(allocator, name),
            .private_identifier => false,
        };
    }
};

/// https://tc39.es/ecma262/#prod-ClassStaticBlock
pub const ClassStaticBlock = struct {
    statement_list: StatementList,

    /// 8.2.6 Static Semantics: LexicallyDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-lexicallydeclarednames
    pub fn collectLexicallyDeclaredNames(
        self: ClassStaticBlock,
        allocator: std.mem.Allocator,
        lexically_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // ClassStaticBlockStatementList : [empty]
        // 1. Return a new empty List.
        // ClassStaticBlockStatementList : StatementList
        // 1. Return the TopLevelLexicallyDeclaredNames of StatementList.
        try self.statement_list.collectTopLevelLexicallyDeclaredNames(allocator, lexically_declared_names);
    }

    /// 8.2.8 Static Semantics: VarDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-vardeclarednames
    pub fn collectVarDeclaredNames(
        self: ClassStaticBlock,
        allocator: std.mem.Allocator,
        var_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // ClassStaticBlockStatementList : [empty]
        // 1. Return a new empty List.
        // ClassStaticBlockStatementList : StatementList
        // 1. Return the TopLevelVarDeclaredNames of StatementList.
        try self.statement_list.collectTopLevelVarDeclaredNames(allocator, var_declared_names);
    }
};

/// https://tc39.es/ecma262/#prod-AsyncFunctionDeclaration
pub const AsyncFunctionDeclaration = struct {
    identifier: ?Identifier,
    formal_parameters: FormalParameters,
    function_body: FunctionBody,
    source_range: SourceRange,

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: AsyncFunctionDeclaration,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // AsyncFunctionDeclaration : async function BindingIdentifier ( FormalParameters ) { AsyncFunctionBody }
        // 1. Return the BoundNames of BindingIdentifier.
        // AsyncFunctionDeclaration : async function ( FormalParameters ) { AsyncFunctionBody }
        // 1. Return « "*default*" ».
        try bound_names.append(allocator, self.identifier orelse "*default*");
    }

    /// 8.2.3 Static Semantics: IsConstantDeclaration
    /// https://tc39.es/ecma262/#sec-static-semantics-isconstantdeclaration
    pub fn isConstantDeclaration(_: AsyncFunctionDeclaration) bool {
        // AsyncFunctionDeclaration :
        //     async function BindingIdentifier ( FormalParameters ) { AsyncFunctionBody }
        //     async function ( FormalParameters ) { AsyncFunctionBody }
        // 1. Return false.
        return false;
    }
};

/// https://tc39.es/ecma262/#prod-AsyncFunctionExpression
pub const AsyncFunctionExpression = struct {
    identifier: ?Identifier,
    formal_parameters: FormalParameters,
    function_body: FunctionBody,
    source_range: SourceRange,
};

/// https://tc39.es/ecma262/#prod-AwaitExpression
pub const AwaitExpression = struct {
    expression: *Expression,
};

/// https://tc39.es/ecma262/#prod-AsyncArrowFunction
pub const AsyncArrowFunction = struct {
    formal_parameters: FormalParameters,
    function_body: FunctionBody,
    source_range: SourceRange,
};

/// https://tc39.es/ecma262/#prod-Script
pub const Script = struct {
    statement_list: StatementList,

    /// 8.2.7 Static Semantics: LexicallyScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-lexicallyscopeddeclarations
    pub fn collectLexicallyScopedDeclarations(
        self: Script,
        allocator: std.mem.Allocator,
        lexically_scoped_declarations: *std.ArrayList(LexicallyScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // Script : [empty]
        // 1. Return a new empty List.
        // ScriptBody : StatementList
        // 1. Return the TopLevelLexicallyScopedDeclarations of StatementList.
        try self.statement_list.collectTopLevelLexicallyScopedDeclarations(allocator, lexically_scoped_declarations);
    }

    /// 8.2.6 Static Semantics: LexicallyDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-lexicallydeclarednames
    pub fn collectLexicallyDeclaredNames(
        self: Script,
        allocator: std.mem.Allocator,
        lexically_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // Script : [empty]
        // 1. Return a new empty List.
        // ScriptBody : StatementList
        // 1. Return the TopLevelLexicallyDeclaredNames of StatementList.
        try self.statement_list.collectTopLevelLexicallyDeclaredNames(allocator, lexically_declared_names);
    }

    /// 8.2.8 Static Semantics: VarDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-vardeclarednames
    pub fn collectVarDeclaredNames(
        self: Script,
        allocator: std.mem.Allocator,
        var_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // Script : [empty]
        // 1. Return a new empty List.
        // ScriptBody : StatementList
        // 1. Return the TopLevelVarDeclaredNames of StatementList.
        try self.statement_list.collectTopLevelVarDeclaredNames(allocator, var_declared_names);
    }

    /// 8.2.9 Static Semantics: VarScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-varscopeddeclarations
    pub fn collectVarScopedDeclarations(
        self: Script,
        allocator: std.mem.Allocator,
        var_scoped_declarations: *std.ArrayList(VarScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // Script : [empty]
        // 1. Return a new empty List.
        // ScriptBody : StatementList
        // 1. Return the TopLevelVarScopedDeclarations of StatementList.
        try self.statement_list.collectTopLevelVarScopedDeclarations(allocator, var_scoped_declarations);
    }

    /// 16.1.2 Static Semantics: ScriptIsStrict
    /// https://tc39.es/ecma262/#sec-scriptisstrict
    pub fn scriptIsStrict(self: Script) bool {
        // 1. If ScriptBody is present and the Directive Prologue of ScriptBody contains a Use
        //    Strict Directive, return true.
        // 2. Return false.
        return self.statement_list.containsDirective("use strict");
    }
};

/// https://tc39.es/ecma262/#prod-Module
pub const Module = struct {
    module_item_list: ModuleItemList,

    pub fn hasTla(self: Module) bool {
        return for (self.module_item_list.items) |module_item| {
            switch (module_item) {
                .statement_list_item => |statement_list_item| {
                    if (statement_list_item.analyze(.is_await_expression)) break true;
                },
                else => {},
            }
        } else false;
    }

    /// 8.2.7 Static Semantics: LexicallyScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-lexicallyscopeddeclarations
    pub fn collectLexicallyScopedDeclarations(
        self: Module,
        allocator: std.mem.Allocator,
        lexically_scoped_declarations: *std.ArrayList(LexicallyScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // Module : [empty]
        // 1. Return a new empty List.
        // ModuleItemList : ModuleItemList ModuleItem
        // 1. Let decls1 be the LexicallyScopedDeclarations of ModuleItemList.
        // 2. Let decls2 be the LexicallyScopedDeclarations of ModuleItem.
        // 3. Return the list-concatenation of decls1 and decls2.
        try self.module_item_list.collectLexicallyScopedDeclarations(allocator, lexically_scoped_declarations);
    }

    /// 8.2.9 Static Semantics: VarScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-varscopeddeclarations
    pub fn collectVarScopedDeclarations(
        self: Module,
        allocator: std.mem.Allocator,
        var_scoped_declarations: *std.ArrayList(VarScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        try self.module_item_list.collectVarScopedDeclarations(allocator, var_scoped_declarations);
    }

    /// 16.2.1.4 Static Semantics: ModuleRequests
    /// https://tc39.es/ecma262/#sec-static-semantics-modulerequests
    pub fn moduleRequests(
        self: Module,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error![]const ModuleRequest {
        // Module : [empty]
        // 1. Return a new empty List.
        if (self.module_item_list.items.len == 0) return &.{};

        // ModuleItemList : ModuleItem
        // 1. Return the ModuleRequests of ModuleItem.
        // ModuleItemList : ModuleItemList ModuleItem
        // 1. Let requests be the ModuleRequests of ModuleItemList.
        // 2. Let additionalRequests be the ModuleRequests of ModuleItem.
        var module_requests: std.ArrayList(ModuleRequest) = .empty;
        defer module_requests.deinit(allocator);
        for (self.module_item_list.items) |module_item| switch (module_item) {
            // ModuleItem : StatementListItem
            .statement_list_item => {
                // 1. Return a new empty List.
            },
            .import_declaration => |import_declaration| {
                try import_declaration.collectModuleRequests(allocator, &module_requests);
            },
            .export_declaration => |export_declaration| {
                try export_declaration.collectModuleRequests(allocator, &module_requests);
            },
        };

        // 3. For each ModuleRequest Record moduleRequest of additionalRequests, do
        //      a. If requests does not contain a ModuleRequest Record otherModuleRequest such that
        //         ModuleRequestsEqual(moduleRequest, otherModuleRequest) is true, then
        //          i. Append moduleRequest to requests.
        var deduplicated: ModuleRequest.ArrayHashMap(void) = .empty;
        for (module_requests.items) |module_request| {
            try deduplicated.put(allocator, module_request, {});
        }

        // 4. Return requests.
        return allocator.dupe(ModuleRequest, deduplicated.keys());
    }

    /// 16.2.2.2 Static Semantics: ImportEntries
    /// https://tc39.es/ecma262/#sec-static-semantics-importentries
    pub fn collectImportEntries(
        self: Module,
        allocator: std.mem.Allocator,
        import_entries: *std.ArrayList(ImportEntry),
    ) std.mem.Allocator.Error!void {
        // Module : [empty]
        // 1. Return a new empty List.
        // ModuleItemList : ModuleItemList ModuleItem
        // 1. Let entries1 be the ImportEntries of ModuleItemList.
        // 2. Let entries2 be the ImportEntries of ModuleItem.
        // 3. Return the list-concatenation of entries1 and entries2.
        for (self.module_item_list.items) |module_item| switch (module_item) {
            // ModuleItem :
            //     ExportDeclaration
            //     StatementListItem
            .export_declaration, .statement_list_item => {
                // 1. Return a new empty List.
            },
            .import_declaration => |import_declaration| {
                //  ImportDeclaration : import ImportClause FromClause WithClause[opt] ;
                if (import_declaration.import_clause) |import_clause| {
                    var module_requests: std.ArrayList(ModuleRequest) = .empty;
                    defer module_requests.deinit(allocator);
                    try import_declaration.collectModuleRequests(allocator, &module_requests);

                    // 1. Let module be the sole element of the ModuleRequests of ImportDeclaration.
                    std.debug.assert(module_requests.items.len == 1);
                    const module = module_requests.items[0];

                    // 2. Return the ImportEntriesForModule of ImportClause with argument module.
                    try import_clause.collectImportEntriesForModule(
                        allocator,
                        import_entries,
                        module,
                    );
                }
                // ImportDeclaration : import ModuleSpecifier WithClause[opt] ;
                // 1. Return a new empty List.
            },
        };
    }

    /// 16.2.3.4 Static Semantics: ExportEntries
    /// https://tc39.es/ecma262/#sec-static-semantics-exportentries
    pub fn collectExportEntries(
        self: Module,
        allocator: std.mem.Allocator,
        export_entries: *std.ArrayList(ExportEntry),
    ) std.mem.Allocator.Error!void {
        // Module : [empty]
        // 1. Return a new empty List.
        // ModuleItemList : ModuleItemList ModuleItem
        // 1. Let entries1 be the ExportEntries of ModuleItemList.
        // 2. Let entries2 be the ExportEntries of ModuleItem.
        // 3. Return the list-concatenation of entries1 and entries2.
        for (self.module_item_list.items) |module_item| switch (module_item) {
            // ModuleItem :
            //     ImportDeclaration
            //     StatementListItem
            .import_declaration, .statement_list_item => {
                // 1. Return a new empty List.
            },
            .export_declaration => |export_declaration| switch (export_declaration) {
                // ExportDeclaration : export ExportFromClause FromClause WithClause[opt] ;
                .export_from => |export_from| {
                    var module_requests: std.ArrayList(ModuleRequest) = .empty;
                    defer module_requests.deinit(allocator);
                    try export_declaration.collectModuleRequests(allocator, &module_requests);

                    // 1. Let module be the sole element of the ModuleRequests of ExportDeclaration.
                    std.debug.assert(module_requests.items.len == 1);
                    const module = module_requests.items[0];

                    // 2. Return the ExportEntriesForModule of ExportFromClause with argument
                    //    module.
                    try export_from.export_from_clause.collectExportEntriesForModule(
                        allocator,
                        export_entries,
                        module,
                    );
                },

                // ExportDeclaration : export NamedExports ;
                .named_exports => |named_exports| {
                    // 1. Return the ExportEntriesForModule of NamedExports with argument null.
                    try named_exports.collectExportEntriesForModule(allocator, export_entries, null);
                },

                // ExportDeclaration : export VariableStatement
                .variable_statement => |variable_statement| {
                    // 1. Let entries be a new empty List.

                    // 2. Let names be the BoundNames of VariableStatement.
                    var names: std.ArrayList(Identifier) = .empty;
                    defer names.deinit(allocator);
                    try variable_statement.variable_declaration_list.collectBoundNames(allocator, &names);
                    try export_entries.ensureUnusedCapacity(allocator, names.items.len);

                    // 3. For each element name of names, do
                    for (names.items) |name| {
                        // a. Append the ExportEntry Record { [[ModuleRequest]]: null,
                        //    [[ImportName]]: null, [[LocalName]]: name, [[ExportName]]: name } to
                        //    entries.
                        export_entries.appendAssumeCapacity(.{
                            .module_request = null,
                            .import_name = null,
                            .local_name = name,
                            .export_name = name,
                        });
                    }

                    // 4. Return entries.
                },

                // ExportDeclaration : export Declaration
                .declaration => |declaration| {
                    // 1. Let entries be a new empty List.

                    // 2. Let names be the BoundNames of Declaration.
                    var names: std.ArrayList(Identifier) = .empty;
                    defer names.deinit(allocator);
                    try declaration.collectBoundNames(allocator, &names);
                    try export_entries.ensureUnusedCapacity(allocator, names.items.len);

                    // 3. For each element name of names, do
                    for (names.items) |name| {
                        // a. Append the ExportEntry Record { [[ModuleRequest]]: null,
                        //    [[ImportName]]: null, [[LocalName]]: name, [[ExportName]]: name } to
                        //    entries.
                        export_entries.appendAssumeCapacity(.{
                            .module_request = null,
                            .import_name = null,
                            .local_name = name,
                            .export_name = name,
                        });
                    }

                    // 4. Return entries.
                },

                // ExportDeclaration : export default HoistableDeclaration
                .default_hoistable_declaration => |hoistable_declaration| {
                    // 1. Let names be the BoundNames of HoistableDeclaration.
                    var names: std.ArrayList(Identifier) = .empty;
                    defer names.deinit(allocator);
                    try hoistable_declaration.collectBoundNames(allocator, &names);

                    // 2. Let localName be the sole element of names.
                    std.debug.assert(names.items.len == 1);
                    const local_name = names.items[0];

                    // 3. Return a List whose sole element is a new ExportEntry Record {
                    //    [[ModuleRequest]]: null, [[ImportName]]: null, [[LocalName]]: localName,
                    //    [[ExportName]]: "default" }.
                    try export_entries.append(allocator, .{
                        .module_request = null,
                        .import_name = null,
                        .local_name = local_name,
                        .export_name = "default",
                    });
                },

                // ExportDeclaration : export default ClassDeclaration
                .default_class_declaration => |class_declaration| {
                    // 1. Let names be the BoundNames of ClassDeclaration.
                    var names: std.ArrayList(Identifier) = .empty;
                    defer names.deinit(allocator);
                    try class_declaration.collectBoundNames(allocator, &names);

                    // 2. Let localName be the sole element of names.
                    std.debug.assert(names.items.len == 1);
                    const local_name = names.items[0];

                    // 3. Return a List whose sole element is a new ExportEntry Record {
                    //    [[ModuleRequest]]: null, [[ImportName]]: null, [[LocalName]]: localName,
                    //    [[ExportName]]: "default" }.
                    try export_entries.append(allocator, .{
                        .module_request = null,
                        .import_name = null,
                        .local_name = local_name,
                        .export_name = "default",
                    });
                },

                // ExportDeclaration : export default AssignmentExpression ;
                .default_expression => {
                    // 1. Let entry be the ExportEntry Record { [[ModuleRequest]]: null,
                    //    [[ImportName]]: null, [[LocalName]]: "*default*",
                    //    [[ExportName]]: "default" }.
                    // 2. Return « entry ».
                    try export_entries.append(allocator, .{
                        .module_request = null,
                        .import_name = null,
                        .local_name = "*default*",
                        .export_name = "default",
                    });
                },
            },
        };
    }
};

/// https://tc39.es/ecma262/#prod-ModuleItemList
pub const ModuleItemList = struct {
    items: []const ModuleItem,

    /// 8.2.6 Static Semantics: LexicallyDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-lexicallydeclarednames
    pub fn collectLexicallyDeclaredNames(
        self: ModuleItemList,
        allocator: std.mem.Allocator,
        lexically_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // ModuleItemList : ModuleItemList ModuleItem
        // 1. Let names1 be the LexicallyDeclaredNames of ModuleItemList.
        // 2. Let names2 be the LexicallyDeclaredNames of ModuleItem.
        // 3. Return the list-concatenation of names1 and names2.
        for (self.items) |module_item| {
            try module_item.collectLexicallyDeclaredNames(allocator, lexically_declared_names);
        }
    }

    /// 8.2.7 Static Semantics: LexicallyScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-lexicallyscopeddeclarations
    pub fn collectLexicallyScopedDeclarations(
        self: ModuleItemList,
        allocator: std.mem.Allocator,
        lexically_scoped_declarations: *std.ArrayList(LexicallyScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        for (self.items) |item| switch (item) {
            .statement_list_item => |statement_list_item| {
                try statement_list_item.collectLexicallyScopedDeclarations(allocator, lexically_scoped_declarations);
            },

            // ModuleItem : ImportDeclaration
            .import_declaration => {
                // 1. Return a new empty List.
            },

            .export_declaration => |export_declaration| switch (export_declaration) {
                // ExportDeclaration :
                //     export ExportFromClause FromClause WithClause[opt] ;
                //     export NamedExports ;
                //     export VariableStatement
                .export_from, .named_exports, .variable_statement => {
                    // 1. Return a new empty List.
                },

                // ExportDeclaration : export Declaration
                .declaration => |declaration| {
                    // 1. Return a List whose sole element is the DeclarationPart of Declaration.
                    switch (declaration.*) {
                        .hoistable_declaration => |hoistable_declaration| try lexically_scoped_declarations.append(allocator, .{ .hoistable_declaration = hoistable_declaration }),
                        .class_declaration => |class_declaration| try lexically_scoped_declarations.append(allocator, .{ .class_declaration = class_declaration }),
                        .lexical_declaration => |lexical_declaration| try lexically_scoped_declarations.append(allocator, .{ .lexical_declaration = lexical_declaration }),
                    }
                },

                // ExportDeclaration : export default HoistableDeclaration
                .default_hoistable_declaration => |hoistable_declaration| {
                    // 1. Return a List whose sole element is the DeclarationPart of
                    //    HoistableDeclaration.
                    try lexically_scoped_declarations.append(allocator, .{ .hoistable_declaration = hoistable_declaration });
                },

                // ExportDeclaration : export default ClassDeclaration
                .default_class_declaration => |class_declaration| {
                    // 1. Return a List whose sole element is ClassDeclaration.
                    try lexically_scoped_declarations.append(allocator, .{ .class_declaration = class_declaration });
                },

                // ExportDeclaration : export default AssignmentExpression ;
                .default_expression => |expression| {
                    // 1. Return a List whose sole element is this ExportDeclaration.
                    try lexically_scoped_declarations.append(allocator, .{ .export_declaration = expression });
                },
            },
        };
    }

    /// 8.2.8 Static Semantics: VarDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-vardeclarednames
    pub fn collectVarDeclaredNames(
        self: ModuleItemList,
        allocator: std.mem.Allocator,
        var_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // ModuleItemList : ModuleItemList ModuleItem
        // 1. Let names1 be the VarDeclaredNames of ModuleItemList.
        // 2. Let names2 be the VarDeclaredNames of ModuleItem.
        // 3. Return the list-concatenation of names1 and names2.
        for (self.items) |module_item| {
            try module_item.collectVarDeclaredNames(allocator, var_declared_names);
        }
    }

    /// 8.2.9 Static Semantics: VarScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-varscopeddeclarations
    pub fn collectVarScopedDeclarations(
        self: ModuleItemList,
        allocator: std.mem.Allocator,
        var_scoped_declarations: *std.ArrayList(VarScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        // ModuleItemList : ModuleItemList ModuleItem
        // 1. Let decls1 be the VarScopedDeclarations of ModuleItemList.
        // 2. Let decls2 be the VarScopedDeclarations of ModuleItem.
        // 3. Return the list-concatenation of decls1 and decls2.
        for (self.items) |module_item| {
            try module_item.collectVarScopedDeclarations(allocator, var_scoped_declarations);
        }
    }
};

/// https://tc39.es/ecma262/#prod-ModuleItem
pub const ModuleItem = union(enum) {
    import_declaration: ImportDeclaration,
    export_declaration: ExportDeclaration,
    statement_list_item: StatementListItem,

    /// 8.2.6 Static Semantics: LexicallyDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-lexicallydeclarednames
    pub fn collectLexicallyDeclaredNames(
        self: ModuleItem,
        allocator: std.mem.Allocator,
        lexically_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        switch (self) {
            // ModuleItem : ImportDeclaration
            .import_declaration => |import_declaration| {
                // 1. Return the BoundNames of ImportDeclaration.
                try import_declaration.collectBoundNames(allocator, lexically_declared_names);
            },

            // ModuleItem : ExportDeclaration
            .export_declaration => |export_declaration| {
                // 1. If ExportDeclaration is `export` VariableStatement, return a new empty List.
                if (export_declaration == .variable_statement) return;

                // 2. Return the BoundNames of ExportDeclaration.
                try export_declaration.collectBoundNames(allocator, lexically_declared_names);
            },

            // ModuleItem : StatementListItem
            .statement_list_item => |statement_list_item| {
                // 1. Return the LexicallyDeclaredNames of StatementListItem.
                try statement_list_item.collectLexicallyDeclaredNames(allocator, lexically_declared_names);
            },
        }
    }

    /// 8.2.8 Static Semantics: VarDeclaredNames
    /// https://tc39.es/ecma262/#sec-static-semantics-vardeclarednames
    pub fn collectVarDeclaredNames(
        self: ModuleItem,
        allocator: std.mem.Allocator,
        var_declared_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        switch (self) {
            // ModuleItem : ImportDeclaration
            .import_declaration => {
                // 1. Return a new empty List.
            },

            // ModuleItem : ExportDeclaration
            .export_declaration => |export_declaration| switch (export_declaration) {
                // 1. If ExportDeclaration is `export` VariableStatement, return the BoundNames of
                //    ExportDeclaration.
                .variable_statement => |variable_statement| {
                    try variable_statement.variable_declaration_list.collectBoundNames(allocator, var_declared_names);
                },

                // 2. Return a new empty List.
                else => {},
            },

            .statement_list_item => |statement_list_item| {
                try statement_list_item.collectVarDeclaredNames(allocator, var_declared_names);
            },
        }
    }

    /// 8.2.9 Static Semantics: VarScopedDeclarations
    /// https://tc39.es/ecma262/#sec-static-semantics-varscopeddeclarations
    pub fn collectVarScopedDeclarations(
        self: ModuleItem,
        allocator: std.mem.Allocator,
        var_scoped_declarations: *std.ArrayList(VarScopedDeclaration),
    ) std.mem.Allocator.Error!void {
        switch (self) {
            // ModuleItem : ImportDeclaration
            .import_declaration => {
                // 1. Return a new empty List.
            },

            // ModuleItem : ExportDeclaration
            .export_declaration => |export_declaration| switch (export_declaration) {
                // 1. If ExportDeclaration is `export` VariableStatement, return the
                //    VarScopedDeclarations of VariableStatement.
                .variable_statement => |variable_statement| {
                    try variable_statement.variable_declaration_list.collectVarScopedDeclarations(allocator, var_scoped_declarations);
                },

                // 2. Return a new empty List.
                else => {},
            },

            .statement_list_item => |statement_list_item| {
                try statement_list_item.collectVarScopedDeclarations(allocator, var_scoped_declarations);
            },
        }
    }
};

/// https://tc39.es/ecma262/#prod-ModuleExportName
pub const ModuleExportName = union(enum) {
    identifier: Identifier,
    string_literal: StringLiteral,
};

/// https://tc39.es/ecma262/#prod-ImportDeclaration
pub const ImportDeclaration = struct {
    import_clause: ?ImportClause,
    module_specifier: StringLiteral,
    with_clause: ?WithClause,

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: ImportDeclaration,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // ImportDeclaration : import ImportClause FromClause ;
        // 1. Return the BoundNames of ImportClause.
        // ImportDeclaration : import ModuleSpecifier ;
        // 1. Return a new empty List.
        if (self.import_clause) |import_clause| {
            try import_clause.collectBoundNames(allocator, bound_names);
        }
    }

    /// 16.2.1.4 Static Semantics: ModuleRequests
    /// https://tc39.es/ecma262/#sec-static-semantics-modulerequests
    pub fn collectModuleRequests(
        self: ImportDeclaration,
        allocator: std.mem.Allocator,
        module_requests: *std.ArrayList(ModuleRequest),
    ) std.mem.Allocator.Error!void {
        // ImportDeclaration : import ImportClause FromClause ;
        // 1. Let specifier be the SV of FromClause.
        // 2. Return a List whose sole element is the ModuleRequest Record {
        //    [[Specifier]]: specifier, [[Attributes]]: « » }.
        // ImportDeclaration : import ImportClause FromClause WithClause ;
        // 1. Let specifier be the SV of FromClause.
        // 2. Let attrs be WithClauseToAttributes of WithClause.
        // 3. Return a List whose sole element is the ModuleRequest Record {
        //    [[Specifier]]: specifier, [[Attributes]]: attrs }.
        // ImportDeclaration : import ModuleSpecifier ;
        // 1. Let specifier be the SV of ModuleSpecifier.
        // 2. Return a List whose sole element is the ModuleRequest Record {
        //    [[Specifier]]: specifier, [[Attributes]]: « » }.
        // ImportDeclaration : import ModuleSpecifier WithClause ;
        // 1. Let specifier be the SV of ModuleSpecifier.
        // 2. Let attrs be WithClauseToAttributes of WithClause.
        // 3. Return a List whose sole element is the ModuleRequest Record {
        //    [[Specifier]]: specifier, [[Attributes]]: attrs }.
        const specifier = try self.module_specifier.stringValue(allocator);
        const attrs = if (self.with_clause) |with_clause|
            try with_clause.toAttributes(allocator)
        else
            &.{};
        const module_request: ModuleRequest = .{
            .specifier = specifier,
            .attributes = attrs,
        };
        try module_requests.append(allocator, module_request);
    }
};

/// https://tc39.es/ecma262/#prod-ImportClause
pub const ImportClause = union(enum) {
    pub const ImportedDefaultBindingAndNamespaceImport = struct {
        imported_default_binding: Identifier,
        namespace_import: Identifier,
    };
    pub const ImportedDefaultBindingAndNamedImports = struct {
        imported_default_binding: Identifier,
        named_imports: ImportsList,
    };

    imported_default_binding: Identifier,
    namespace_import: Identifier,
    named_imports: ImportsList,
    imported_default_binding_and_namespace_import: ImportedDefaultBindingAndNamespaceImport,
    imported_default_binding_and_named_imports: ImportedDefaultBindingAndNamedImports,

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: ImportClause,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // ImportClause : ImportedDefaultBinding , NameSpaceImport
        // 1. Let names1 be the BoundNames of ImportedDefaultBinding.
        // 2. Let names2 be the BoundNames of NameSpaceImport.
        // 3. Return the list-concatenation of names1 and names2.
        // ImportClause : ImportedDefaultBinding , NamedImports
        // 1. Let names1 be the BoundNames of ImportedDefaultBinding.
        // 2. Let names2 be the BoundNames of NamedImports.
        // 3. Return the list-concatenation of names1 and names2.
        switch (self) {
            .imported_default_binding => |imported_default_binding| try bound_names.append(allocator, imported_default_binding),
            .namespace_import => |namespace_import| try bound_names.append(allocator, namespace_import),
            .named_imports => |named_imports| try named_imports.collectBoundNames(allocator, bound_names),
            .imported_default_binding_and_namespace_import => |x| {
                try bound_names.append(allocator, x.imported_default_binding);
                try bound_names.append(allocator, x.namespace_import);
            },
            .imported_default_binding_and_named_imports => |x| {
                try bound_names.append(allocator, x.imported_default_binding);
                try x.named_imports.collectBoundNames(allocator, bound_names);
            },
        }
    }

    /// 16.2.2.3 Static Semantics: ImportEntriesForModule
    /// https://tc39.es/ecma262/#sec-static-semantics-importentriesformodule
    pub fn collectImportEntriesForModule(
        self: ImportClause,
        allocator: std.mem.Allocator,
        import_entries: *std.ArrayList(ImportEntry),
        module: ModuleRequest,
    ) std.mem.Allocator.Error!void {
        switch (self) {
            // ImportedDefaultBinding : ImportedBinding
            .imported_default_binding => |imported_binding| {
                // 1. Let localName be the sole element of the BoundNames of ImportedBinding.
                const local_name = imported_binding;

                // 2. Let defaultEntry be the ImportEntry Record { [[ModuleRequest]]: module,
                //    [[ImportName]]: "default", [[LocalName]]: localName }.
                const default_entry: ImportEntry = .{
                    .module_request = module,
                    .import_name = .{ .string = "default" },
                    .local_name = local_name,
                };

                // 3. Return « defaultEntry ».
                try import_entries.append(allocator, default_entry);
            },

            // NameSpaceImport : * as ImportedBinding
            .namespace_import => |imported_binding| {
                // 1. Let localName be the StringValue of ImportedBinding.
                const local_name = imported_binding;

                // 2. Let entry be the ImportEntry Record { [[ModuleRequest]]: module,
                //    [[ImportName]]: namespace, [[LocalName]]: localName }.
                const entry: ImportEntry = .{
                    .module_request = module,
                    .import_name = .namespace,
                    .local_name = local_name,
                };

                // 3. Return « entry ».
                try import_entries.append(allocator, entry);
            },

            // NamedImports : { }
            // 1. Return a new empty List.
            // ImportsList : ImportsList , ImportSpecifier
            // 1. Let specs1 be the ImportEntriesForModule of ImportsList with argument module.
            // 2. Let specs2 be the ImportEntriesForModule of ImportSpecifier with argument module.
            // 3. Return the list-concatenation of specs1 and specs2.
            .named_imports => |imports_list| for (imports_list.items) |import_specifier| {
                // ImportSpecifier : ModuleExportName as ImportedBinding
                if (import_specifier.module_export_name) |module_export_name| {
                    // 1. Let importName be the StringValue of ModuleExportName.
                    const import_name = switch (module_export_name) {
                        .identifier => |identifier| identifier,
                        .string_literal => |string_literal| try (try string_literal.stringValue(
                            allocator,
                        )).toWtf8(allocator),
                    };

                    // 2. Let localName be the StringValue of ImportedBinding.
                    const local_name = import_specifier.imported_binding;

                    // 3. Let entry be the ImportEntry Record { [[ModuleRequest]]: module,
                    //    [[ImportName]]: importName, [[LocalName]]: localName }.
                    const entry: ImportEntry = .{
                        .module_request = module,
                        .import_name = .{ .string = import_name },
                        .local_name = local_name,
                    };

                    // 4. Return « entry ».
                    try import_entries.append(allocator, entry);
                }
                // ImportSpecifier : ImportedBinding
                else {
                    // 1. Let localName be the sole element of the BoundNames of ImportedBinding.
                    const local_name = import_specifier.imported_binding;

                    // 2. Let entry be the ImportEntry Record { [[ModuleRequest]]: module,
                    //    [[ImportName]]: localName, [[LocalName]]: localName }.
                    const entry: ImportEntry = .{
                        .module_request = module,
                        .import_name = .{ .string = local_name },
                        .local_name = local_name,
                    };

                    // 3. Return « entry ».
                    try import_entries.append(allocator, entry);
                }
            },

            // ImportClause : ImportedDefaultBinding , NameSpaceImport
            .imported_default_binding_and_namespace_import => |x| {
                // 1. Let entries1 be the ImportEntriesForModule of ImportedDefaultBinding with
                //    argument module.
                // 2. Let entries2 be the ImportEntriesForModule of NameSpaceImport with argument
                //    module.
                // 3. Return the list-concatenation of entries1 and entries2.
                try collectImportEntriesForModule(
                    .{ .imported_default_binding = x.imported_default_binding },
                    allocator,
                    import_entries,
                    module,
                );
                try collectImportEntriesForModule(
                    .{ .namespace_import = x.namespace_import },
                    allocator,
                    import_entries,
                    module,
                );
            },

            // ImportClause : ImportedDefaultBinding , NamedImports
            .imported_default_binding_and_named_imports => |x| {
                // 1. Let entries1 be the ImportEntriesForModule of ImportedDefaultBinding with
                //    argument module.
                // 2. Let entries2 be the ImportEntriesForModule of NamedImports with argument
                //    module.
                // 3. Return the list-concatenation of entries1 and entries2.
                try collectImportEntriesForModule(
                    .{ .imported_default_binding = x.imported_default_binding },
                    allocator,
                    import_entries,
                    module,
                );
                try collectImportEntriesForModule(
                    .{ .named_imports = x.named_imports },
                    allocator,
                    import_entries,
                    module,
                );
            },
        }
    }
};

/// https://tc39.es/ecma262/#prod-ImportsList
pub const ImportsList = struct {
    items: []const ImportSpecifier,

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: ImportsList,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // NamedImports : { }
        // 1. Return a new empty List.
        // ImportsList : ImportsList , ImportSpecifier
        // 1. Let names1 be the BoundNames of ImportsList.
        // 2. Let names2 be the BoundNames of ImportSpecifier.
        // 3. Return the list-concatenation of names1 and names2.
        for (self.items) |import_specifier| {
            try import_specifier.collectBoundNames(allocator, bound_names);
        }
    }
};

/// https://tc39.es/ecma262/#prod-ImportSpecifier
pub const ImportSpecifier = struct {
    module_export_name: ?ModuleExportName,
    imported_binding: Identifier,

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: ImportSpecifier,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        // ImportSpecifier : ModuleExportName as ImportedBinding
        // 1. Return the BoundNames of ImportedBinding.
        try bound_names.append(allocator, self.imported_binding);
    }
};

/// https://tc39.es/ecma262/#prod-WithClause
pub const WithClause = struct {
    pub const Item = struct {
        key: AttributeKey,
        value: StringLiteral,
    };

    items: []const Item,

    /// 16.2.2.4 Static Semantics: WithClauseToAttributes
    /// https://tc39.es/ecma262/#sec-withclausetoattributes
    pub fn toAttributes(
        self: WithClause,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error![]const ImportAttribute {
        // WithClause : with { }
        // 1. Return a new empty List.
        // WithClause : with { WithEntries ,[opt] }
        // 1. Let attrs be WithClauseToAttributes of WithEntries.
        // 2. Sort attrs according to the lexicographic order of their [[Key]] field, treating the
        //    value of each such field as a sequence of UTF-16 code unit values. NOTE: This sorting
        //    is observable only in that hosts are prohibited from changing behaviour based on the
        //    order in which attributes are enumerated.
        // 3. Return attrs.
        // WithEntries : AttributeKey : StringLiteral
        // 1. Let key be the PropName of AttributeKey.
        // 2. Let entry be the ImportAttribute Record { [[Key]]: key, [[Value]]: the SV of
        //    StringLiteral }.
        // 3. Return « entry ».
        // WithEntries : AttributeKey : StringLiteral , WithEntries
        // 1. Let key be the PropName of AttributeKey.
        // 2. Let entry be the ImportAttribute Record { [[Key]]: key, [[Value]]: the SV of
        //    StringLiteral }.
        // 3. Let rest be WithClauseToAttributes of WithEntries.
        // 4. Return the list-concatenation of « entry » and rest.
        var attributes: std.ArrayList(ImportAttribute) = .empty;
        try attributes.ensureUnusedCapacity(allocator, self.items.len);
        for (self.items) |item| {
            const key = switch (item.key) {
                .identifier => |identifier| try String.fromUtf8Alloc(allocator, identifier),
                .string_literal => |string_literal| try string_literal.stringValue(allocator),
            };
            const value = try item.value.stringValue(allocator);
            attributes.appendAssumeCapacity(.{ .key = key, .value = value });
        }
        std.mem.sort(ImportAttribute, attributes.items, {}, struct {
            fn lessThanFn(_: void, lhs: ImportAttribute, rhs: ImportAttribute) bool {
                const lhs_len = lhs.key.length;
                const rhs_len = rhs.key.length;
                for (0..@min(lhs_len, rhs_len)) |i| {
                    const cx = lhs.key.codeUnitAt(@intCast(i));
                    const cy = rhs.key.codeUnitAt(@intCast(i));
                    if (cx < cy) return true;
                    if (cx > cy) return false;
                }
                return lhs_len < rhs_len;
            }
        }.lessThanFn);
        return attributes.toOwnedSlice(allocator);
    }
};

/// https://tc39.es/ecma262/#prod-AttributeKey
pub const AttributeKey = union(enum) {
    identifier: Identifier,
    string_literal: StringLiteral,
};

/// https://tc39.es/ecma262/#prod-ExportDeclaration
pub const ExportDeclaration = union(enum) {
    pub const ExportFrom = struct {
        export_from_clause: ExportFromClause,
        module_specifier: StringLiteral,
        with_clause: ?WithClause,
    };

    export_from: ExportFrom,
    named_exports: NamedExports,
    declaration: *Declaration,
    variable_statement: VariableStatement,
    default_hoistable_declaration: HoistableDeclaration,
    default_class_declaration: ClassDeclaration,
    default_expression: Expression,

    /// 8.2.1 Static Semantics: BoundNames
    /// https://tc39.es/ecma262/#sec-static-semantics-boundnames
    pub fn collectBoundNames(
        self: ExportDeclaration,
        allocator: std.mem.Allocator,
        bound_names: *std.ArrayList(Identifier),
    ) std.mem.Allocator.Error!void {
        switch (self) {
            // ExportDeclaration :
            //     export ExportFromClause FromClause WithClause[opt] ;
            //     export NamedExports ;
            .export_from, .named_exports => {
                // 1. Return a new empty List.
            },

            // ExportDeclaration : export VariableStatement
            .variable_statement => |variable_statement| {
                // 1. Return the BoundNames of VariableStatement.
                try variable_statement.variable_declaration_list.collectBoundNames(allocator, bound_names);
            },

            // ExportDeclaration : export Declaration
            .declaration => |declaration| {
                // 1. Return the BoundNames of Declaration.
                try declaration.collectBoundNames(allocator, bound_names);
            },

            // ExportDeclaration : export default HoistableDeclaration
            .default_hoistable_declaration => |hoistable_declaration| {
                // 1. Let declNames be the BoundNames of HoistableDeclaration.
                var decl_names: std.ArrayList(Identifier) = .empty;
                defer decl_names.deinit(allocator);
                try hoistable_declaration.collectBoundNames(allocator, &decl_names);

                // 2. If declNames does not include the element "*default*", append "*default*" to
                //    declNames.
                if (!containsSlice(decl_names.items, "*default*")) {
                    try decl_names.append(allocator, "*default*");
                }

                // 3. Return declNames.
                try bound_names.appendSlice(allocator, decl_names.items);
            },

            // ExportDeclaration : export default ClassDeclaration
            .default_class_declaration => |class_declaration| {
                // 1. Let declNames be the BoundNames of ClassDeclaration.
                var decl_names: std.ArrayList(Identifier) = .empty;
                defer decl_names.deinit(allocator);
                try class_declaration.collectBoundNames(allocator, &decl_names);

                // 2. If declNames does not include the element "*default*", append "*default*" to
                //    declNames.
                if (!containsSlice(decl_names.items, "*default*")) {
                    try decl_names.append(allocator, "*default*");
                }

                // 3. Return declNames.
                try bound_names.appendSlice(allocator, decl_names.items);
            },

            // ExportDeclaration : export default AssignmentExpression ;
            .default_expression => {
                // 1. Return « "*default*" ».
                try bound_names.append(allocator, "*default*");
            },
        }
    }

    /// 16.2.1.4 Static Semantics: ModuleRequests
    /// https://tc39.es/ecma262/#sec-static-semantics-modulerequests
    pub fn collectModuleRequests(
        self: ExportDeclaration,
        allocator: std.mem.Allocator,
        module_requests: *std.ArrayList(ModuleRequest),
    ) std.mem.Allocator.Error!void {
        switch (self) {
            // ExportDeclaration : export ExportFromClause FromClause ;
            // 1. Let specifier be the SV of FromClause.
            // 2. Return a List whose sole element is the ModuleRequest Record {
            //    [[Specifier]]: specifier, [[Attributes]]: « » }.
            // ExportDeclaration : export ExportFromClause FromClause WithClause ;
            // 1. Let specifier be the SV of FromClause.
            // 2. Let attrs be WithClauseToAttributes of WithClause.
            // 3. Return a List whose sole element is the ModuleRequest Record {
            //    [[Specifier]]: specifier, [[Attributes]]: attrs }.
            .export_from => |export_from| {
                const specifier = try export_from.module_specifier.stringValue(allocator);
                const attrs = if (export_from.with_clause) |with_clause|
                    try with_clause.toAttributes(allocator)
                else
                    &.{};
                const module_request: ModuleRequest = .{
                    .specifier = specifier,
                    .attributes = attrs,
                };
                try module_requests.append(allocator, module_request);
            },

            // ExportDeclaration :
            // export NamedExports ;
            // export VariableStatement
            // export Declaration
            // export default HoistableDeclaration
            // export default ClassDeclaration
            // export default AssignmentExpression ;
            .named_exports,
            .variable_statement,
            .declaration,
            .default_hoistable_declaration,
            .default_class_declaration,
            .default_expression,
            => {
                // 1. Return a new empty List.
            },
        }
    }
};

/// https://tc39.es/ecma262/#prod-ExportFromClause
pub const ExportFromClause = union(enum) {
    star,
    star_as: ModuleExportName,
    named_exports: NamedExports,

    /// 16.2.3.5 Static Semantics: ExportEntriesForModule
    /// https://tc39.es/ecma262/#sec-static-semantics-exportentriesformodule
    pub fn collectExportEntriesForModule(
        self: ExportFromClause,
        allocator: std.mem.Allocator,
        export_entries: *std.ArrayList(ExportEntry),
        module: ?ModuleRequest,
    ) std.mem.Allocator.Error!void {
        switch (self) {
            // ExportFromClause : *
            .star => {
                // 1. Let entry be the ExportEntry Record { [[ModuleRequest]]: module,
                //    [[ImportName]]: all-but-default, [[LocalName]]: null, [[ExportName]]: null }.
                const entry: ExportEntry = .{
                    .module_request = module,
                    .import_name = .all_but_default,
                    .local_name = null,
                    .export_name = null,
                };

                // 2. Return « entry ».
                try export_entries.append(allocator, entry);
            },
            // ExportFromClause : * as ModuleExportName
            .star_as => |module_export_name| {
                // 1. Let exportName be the StringValue of ModuleExportName.
                const export_name = switch (module_export_name) {
                    .identifier => |identifier| identifier,
                    .string_literal => |string_literal| try (try string_literal.stringValue(allocator)).toWtf8(allocator),
                };

                // 2. Let entry be the ExportEntry Record { [[ModuleRequest]]: module,
                //    [[ImportName]]: namespace, [[LocalName]]: null, [[ExportName]]: exportName }.
                const entry: ExportEntry = .{
                    .module_request = module,
                    .import_name = .namespace,
                    .local_name = null,
                    .export_name = export_name,
                };

                // 3. Return « entry ».
                try export_entries.append(allocator, entry);
            },
            .named_exports => |named_exports| {
                try named_exports.collectExportEntriesForModule(
                    allocator,
                    export_entries,
                    module,
                );
            },
        }
    }
};

/// https://tc39.es/ecma262/#prod-NamedExports
pub const NamedExports = struct {
    exports_list: ExportsList,

    /// 16.2.3.5 Static Semantics: ExportEntriesForModule
    /// https://tc39.es/ecma262/#sec-static-semantics-exportentriesformodule
    pub fn collectExportEntriesForModule(
        self: NamedExports,
        allocator: std.mem.Allocator,
        export_entries: *std.ArrayList(ExportEntry),
        module: ?ModuleRequest,
    ) std.mem.Allocator.Error!void {
        // ExportsList : ExportsList , ExportSpecifier
        // 1. Let specs1 be the ExportEntriesForModule of ExportsList with argument module.
        // 2. Let specs2 be the ExportEntriesForModule of ExportSpecifier with argument module.
        // 3. Return the list-concatenation of specs1 and specs2.
        try export_entries.ensureUnusedCapacity(allocator, self.exports_list.items.len);
        for (self.exports_list.items) |export_specifier| {
            // ExportSpecifier : ModuleExportName
            if (export_specifier.alias == null) {
                // 1. Let sourceName be the StringValue of ModuleExportName.
                const source_name = switch (export_specifier.name) {
                    .identifier => |identifier| identifier,
                    .string_literal => |string_literal| try (try string_literal.stringValue(allocator)).toWtf8(allocator),
                };

                // 2. If module is null, then
                const local_name: ?[]const u8, const import_name: ?[]const u8 = if (module == null) blk: {
                    // a. Let localName be sourceName.
                    // b. Let importName be null.
                    break :blk .{ source_name, null };
                } else blk: {
                    // 3. Else,
                    // a. Let localName be null.
                    // b. Let importName be sourceName.
                    break :blk .{ null, source_name };
                };

                // 4. Return a List whose sole element is a new ExportEntry Record {
                //    [[ModuleRequest]]: module, [[ImportName]]: importName,
                //    [[LocalName]]: localName, [[ExportName]]: sourceName }.
                export_entries.appendAssumeCapacity(.{
                    .module_request = module,
                    .import_name = if (import_name) |string| .{ .string = string } else null,
                    .local_name = local_name,
                    .export_name = source_name,
                });
            }
            // ExportSpecifier : ModuleExportName as ModuleExportName
            else {
                // 1. Let sourceName be the StringValue of the first ModuleExportName.
                const source_name = switch (export_specifier.name) {
                    .identifier => |identifier| identifier,
                    .string_literal => |string_literal| try (try string_literal.stringValue(allocator)).toWtf8(allocator),
                };

                // 2. Let exportName be the StringValue of the second ModuleExportName.
                const export_name = switch (export_specifier.alias.?) {
                    .identifier => |identifier| identifier,
                    .string_literal => |string_literal| try (try string_literal.stringValue(allocator)).toWtf8(allocator),
                };

                // 3. If module is null, then
                const local_name: ?[]const u8, const import_name: ?[]const u8 = if (module == null) blk: {
                    // a. Let localName be sourceName.
                    // b. Let importName be null.
                    break :blk .{ source_name, null };
                } else blk: {
                    // 4. Else,
                    // a. Let localName be null.
                    // b. Let importName be sourceName.
                    break :blk .{ null, source_name };
                };

                // 5. Return a List whose sole element is a new ExportEntry Record {
                //    [[ModuleRequest]]: module, [[ImportName]]: importName,
                //    [[LocalName]]: localName, [[ExportName]]: exportName }.
                export_entries.appendAssumeCapacity(.{
                    .module_request = module,
                    .import_name = if (import_name) |string| .{ .string = string } else null,
                    .local_name = local_name,
                    .export_name = export_name,
                });
            }
        }
    }
};

/// https://tc39.es/ecma262/#prod-ExportsList
pub const ExportsList = struct {
    items: []const ExportSpecifier,
};

/// https://tc39.es/ecma262/#prod-ExportSpecifier
pub const ExportSpecifier = struct {
    name: ModuleExportName,
    alias: ?ModuleExportName,
};
