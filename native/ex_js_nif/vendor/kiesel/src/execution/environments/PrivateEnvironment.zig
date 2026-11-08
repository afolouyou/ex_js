//! 9.2 PrivateEnvironment Records
//! https://tc39.es/ecma262/#sec-privateenvironment-records

const std = @import("std");

const types = @import("../../types.zig");

const PrivateName = types.PrivateName;

const PrivateEnvironment = @This();

/// [[OuterPrivateEnvironment]]
outer_private_environment: ?*PrivateEnvironment,

/// [[Names]]
names: std.StringHashMapUnmanaged(PrivateName),

/// 9.2.1.2 ResolvePrivateIdentifier ( privateEnv, identifier )
/// https://tc39.es/ecma262/#sec-resolve-private-identifier
pub fn resolvePrivateIdentifier(
    self: *const PrivateEnvironment,
    identifier: []const u8,
) PrivateName {
    // 1. Let names be privateEnv.[[Names]].
    // 2. For each Private Name privateName of names, do
    //     a. If privateName.[[Description]] is identifier, then
    if (self.names.get(identifier)) |private_name| {
        // i. Return privateName.
        return private_name;
    }

    // 3. Let outerPrivateEnv be privateEnv.[[OuterPrivateEnvironment]].
    // 4. Assert: outerPrivateEnv is not null.
    const outer_private_env = self.outer_private_environment.?;

    // 5. Return ResolvePrivateIdentifier(outerPrivateEnv, identifier).
    return outer_private_env.resolvePrivateIdentifier(identifier);
}
