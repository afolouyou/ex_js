//! 6.2.13 The ClassStaticBlockDefinition Record Specification Type
//! https://tc39.es/ecma262/#sec-classstaticblockdefinition-record-specification-type

const builtins = @import("../../builtins.zig");

/// [[BodyFunction]]
body_function: *builtins.ECMAScriptFunction,
