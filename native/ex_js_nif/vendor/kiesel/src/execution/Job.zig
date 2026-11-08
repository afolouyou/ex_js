//! 9.5 Jobs and Host Operations to Enqueue Jobs
//! https://tc39.es/ecma262/#sec-jobs

const execution = @import("../execution.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const Object = types.Object;
const Value = types.Value;

func: *const fn (captures: *anyopaque) Agent.Error!Value,
captures: *anyopaque,

/// 9.5.1 JobCallback Records
/// https://tc39.es/ecma262/#sec-jobcallback-records
pub const Callback = struct {
    /// [[Callback]]
    callback: *Object,

    /// [[HostDefined]]
    host_defined: ?*anyopaque,
};
