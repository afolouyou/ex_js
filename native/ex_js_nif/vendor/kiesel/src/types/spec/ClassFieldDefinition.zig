//! 6.2.11 The ClassFieldDefinition Record Specification Type
//! https://tc39.es/ecma262/#sec-classfielddefinition-record-specification-type

const builtins = @import("../../builtins.zig");
const types = @import("../../types.zig");

const PropertyKeyOrPrivateName = types.PropertyKeyOrPrivateName;

/// [[Name]]
name: PropertyKeyOrPrivateName,

/// [[Initializer]]
initializer: ?*builtins.ECMAScriptFunction,
