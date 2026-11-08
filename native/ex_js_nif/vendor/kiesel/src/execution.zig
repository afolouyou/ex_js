const environments = @import("execution/environments.zig");

pub const Agent = @import("execution/Agent.zig");
pub const DeclarativeEnvironment = environments.DeclarativeEnvironment;
pub const Environment = environments.Environment;
pub const ExecutionContext = @import("execution/ExecutionContext.zig");
pub const GlobalEnvironment = environments.GlobalEnvironment;
pub const HostHooks = @import("execution/HostHooks.zig");
pub const Job = @import("execution/Job.zig");
pub const ObjectEnvironment = environments.ObjectEnvironment;
pub const PrivateEnvironment = environments.PrivateEnvironment;
pub const Realm = @import("execution/Realm.zig");
pub const ScriptOrModule = @import("execution/ExecutionContext.zig").ScriptOrModule;
pub const newDeclarativeEnvironment = environments.newDeclarativeEnvironment;
pub const newFunctionEnvironment = environments.newFunctionEnvironment;
pub const newGlobalEnvironment = environments.newGlobalEnvironment;
pub const newModuleEnvironment = environments.newModuleEnvironment;
pub const newObjectEnvironment = environments.newObjectEnvironment;
pub const newPrivateEnvironment = environments.newPrivateEnvironment;

test {
    _ = environments;

    _ = Agent;
    _ = ExecutionContext;
    _ = Realm;
}
