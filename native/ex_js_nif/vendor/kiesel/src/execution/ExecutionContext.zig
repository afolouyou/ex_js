//! 9.4 Execution Contexts
//! https://tc39.es/ecma262/#sec-execution-contexts

const builtins = @import("../builtins.zig");
const environments = @import("environments.zig");
const language = @import("../language.zig");
const types = @import("../types.zig");

const Environment = environments.Environment;
const Module = language.Module;
const Object = types.Object;
const PrivateEnvironment = environments.PrivateEnvironment;
const Realm = @import("Realm.zig");
const Script = language.Script;

pub const ScriptOrModule = union(enum) {
    script: *Script,
    module: Module,
};

pub const Origin = union(enum) {
    function: *Object,
    eval: []const u8,
    script,
    module,
    realm,
};

/// Function
origin: Origin,

/// Realm
realm: *Realm,

/// ScriptOrModule
script_or_module: ?ScriptOrModule,

/// Table 26: Additional State Components for ECMAScript Code Execution Contexts
/// https://tc39.es/ecma262/#table-additional-state-components-for-ecmascript-code-execution-contexts
///
/// NOTE: This is set everywhere except for the realm and builtin function execution contexts and
///       never conditionally accessed, so we set it to `undefined` instead of making the field
///       nullable to save 8 bytes and a bunch of null-unwrapping.
ecmascript_code: struct {
    /// LexicalEnvironment
    lexical_environment: Environment,

    /// VariableEnvironment
    variable_environment: Environment,

    /// PrivateEnvironment
    private_environment: ?*PrivateEnvironment,
},

/// Table 27: Additional State Components for Generator Execution Contexts
/// https://tc39.es/ecma262/#table-additional-state-components-for-generator-execution-contexts
generator: union(enum) {
    unset,
    generator: *builtins.Generator,
    async_generator: *builtins.AsyncGenerator,
} = .unset,
