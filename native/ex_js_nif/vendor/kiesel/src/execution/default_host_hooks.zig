const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const language = @import("../language.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const ByteLength = types.ByteLength;
const Cell = builtins.finalization_registry.Cell;
const HostHooks = execution.HostHooks;
const ImportedModulePayload = language.ImportedModulePayload;
const ImportedModuleReferrer = language.ImportedModuleReferrer;
const Job = execution.Job;
const ModuleRequest = language.ModuleRequest;
const Object = types.Object;
const Realm = execution.Realm;
const SourceTextModule = language.SourceTextModule;
const String = types.String;
const Value = types.Value;
const cleanupFinalizationRegistry = builtins.cleanupFinalizationRegistry;
const finishLoadingImportedModule = language.finishLoadingImportedModule;

// These are imported directly from the source as Temporal might not be enabled
const ns_min_instant = @import("../builtins/temporal/instant.zig").ns_min_instant;
const ns_max_instant = @import("../builtins/temporal/instant.zig").ns_max_instant;

/// 7.3.29 HostEnsureCanAddPrivateElement ( obj )
/// https://tc39.es/ecma262/#sec-hostensurecanaddprivateelement
pub fn hostEnsureCanAddPrivateElement(_: *Agent, _: *Object) Agent.Error!void {
    // The default implementation of HostEnsureCanAddPrivateElement is to return
    // NormalCompletion(unused).
}

/// 9.5.2 HostMakeJobCallback ( callback )
/// https://tc39.es/ecma262/#sec-hostmakejobcallback
pub fn hostMakeJobCallback(callback: *Object) Job.Callback {
    // 1. Return the JobCallback Record { [[Callback]]: callback, [[HostDefined]]: empty }.
    return .{ .callback = callback, .host_defined = null };
}

/// 9.5.3 HostCallJobCallback ( jobCallback, thisValue, argList )
/// https://tc39.es/ecma262/#sec-hostcalljobcallback
pub fn hostCallJobCallback(
    agent: *Agent,
    job_callback: Job.Callback,
    this_value: Value,
    arg_list: []const Value,
) Agent.Error!Value {
    // 1. Assert: IsCallable(jobCallback.[[Callback]]) is true.
    std.debug.assert(Value.from(job_callback.callback).isCallable());

    // 2. Return ? Call(jobCallback.[[Callback]], thisValue, argList).
    return job_callback.callback.call(agent, this_value, arg_list);
}

/// 9.5.4 HostEnqueueGenericJob ( job, realm )
/// https://tc39.es/ecma262/#sec-hostenqueuegenericjob
pub fn hostEnqueueGenericJob(agent: *Agent, job: Job, realm: *Realm) std.mem.Allocator.Error!void {
    try agent.queued_jobs.append(agent.gc_allocator, .{ .job = job, .realm = realm });
}

/// 9.5.5 HostEnqueuePromiseJob ( job, realm )
/// https://tc39.es/ecma262/#sec-hostenqueuepromisejob
pub fn hostEnqueuePromiseJob(agent: *Agent, job: Job, realm: ?*Realm) std.mem.Allocator.Error!void {
    try agent.queued_jobs.append(agent.gc_allocator, .{ .job = job, .realm = realm });
}

/// 9.9.4.1 HostEnqueueFinalizationRegistryCleanupJob ( finalizationRegistry )
/// https://tc39.es/ecma262/#sec-host-cleanup-finalization-registry
pub fn hostEnqueueFinalizationRegistryCleanupJob(
    agent: *Agent,
    cell: *Cell,
) std.mem.Allocator.Error!void {
    // Let cleanupJob be a new Job Abstract Closure with no parameters that captures
    // finalizationRegistry and performs the following steps when called:
    const cleanup_job: Job = .{
        .captures = cell,
        .func = struct {
            fn cleanupJob(captures: *anyopaque) Agent.Error!Value {
                // 1. Let cleanupResult be Completion(CleanupFinalizationRegistry(
                //    finalizationRegistry)).
                const cell_: *Cell = @ptrCast(@alignCast(captures));
                cleanupFinalizationRegistry(cell_) catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                    error.ExceptionThrown => {
                        // 2. If cleanupResult is an abrupt completion, perform any host-defined
                        //    steps for reporting the error.
                    },
                };

                // 3. Return unused.
                return .undefined;
            }
        }.cleanupJob,
    };

    // An implementation of HostEnqueueFinalizationRegistryCleanupJob schedules cleanupJob
    // to be performed at some future time, if possible. It must also conform to the
    // requirements in 9.5.
    try agent.queued_jobs.append(agent.gc_allocator, .{ .job = cleanup_job, .realm = null });
}

/// 13.3.12.1.1 HostGetImportMetaProperties ( moduleRecord )
/// https://tc39.es/ecma262/#sec-hostgetimportmetaproperties
pub fn hostGetImportMetaProperties(
    _: *Agent,
    _: *SourceTextModule,
) error{}!HostHooks.ImportMetaProperties {
    return .empty;
}

/// 13.3.12.1.2 HostFinalizeImportMeta ( importMeta, moduleRecord )
/// https://tc39.es/ecma262/#sec-hostfinalizeimportmeta
pub fn hostFinalizeImportMeta(_: *Object, _: *SourceTextModule) void {
    // The default implementation of HostFinalizeImportMeta is to return unused.
}

/// 16.2.1.10 HostLoadImportedModule ( referrer, moduleRequest, hostDefined, payload )
/// https://tc39.es/ecma262/#sec-HostLoadImportedModule
pub fn hostLoadImportedModule(
    agent: *Agent,
    referrer: ImportedModuleReferrer,
    module_request: ModuleRequest,
    _: ?*anyopaque,
    payload: ImportedModulePayload,
) std.mem.Allocator.Error!void {
    const result = agent.throwException(.internal_error, "Module loading is disabled", .{});
    try finishLoadingImportedModule(agent, referrer, module_request, payload, result);
}

/// 16.2.1.12.1 HostGetSupportedImportAttributes ( )
/// https://tc39.es/ecma262/#sec-hostgetsupportedimportattributes
pub fn hostGetSupportedImportAttributes(
    _: *Agent,
) std.mem.Allocator.Error!HostHooks.SupportedImportAttributes {
    // The default implementation of HostGetSupportedImportAttributes is to return a new empty List.
    return .empty;
}

/// 19.2.1.2 HostEnsureCanCompileStrings ( calleeRealm, paramStrings, bodyString, direct )
/// https://tc39.es/ecma262/#sec-hostensurecancompilestrings
pub fn hostEnsureCanCompileStrings(
    _: *Realm,
    _: []const *const String,
    _: *const String,
    _: bool,
) error{}!void {
    // The default implementation of HostEnsureCanCompileStrings is to return NormalCompletion(unused).
}

/// 20.2.5 HostHasSourceTextAvailable ( func )
/// https://tc39.es/ecma262/#sec-hosthassourcetextavailable
pub fn hostHasSourceTextAvailable(_: *Object) bool {
    // The default implementation of HostHasSourceTextAvailable is to return true.
    return true;
}

/// 25.1.3.8 HostResizeArrayBuffer ( buffer, newByteLength )
/// https://tc39.es/ecma262/#sec-hostresizearraybuffer
pub fn hostResizeArrayBuffer(
    _: *builtins.ArrayBuffer,
    _: ByteLength,
) error{}!HostHooks.ResizeArrayBufferHandled {
    // The default implementation of HostResizeArrayBuffer is to return NormalCompletion(unhandled).
    return .unhandled;
}

/// 25.2.2.4 HostGrowSharedArrayBuffer ( buffer, newByteLength )
/// https://tc39.es/ecma262/#sec-hostgrowsharedarraybuffer
pub fn hostGrowSharedArrayBuffer(
    _: *builtins.ArrayBuffer,
    _: ByteLength,
) error{}!HostHooks.GrowSharedArrayBufferHandled {
    // The default implementation of HostGrowSharedArrayBuffer is to return
    // NormalCompletion(unhandled).
    return .unhandled;
}

/// 27.5.1.9 HostPromiseRejectionTracker ( promise, operation )
/// https://tc39.es/ecma262/#sec-host-promise-rejection-tracker
pub fn hostPromiseRejectionTracker(
    _: *Agent,
    _: *builtins.Promise,
    _: HostHooks.PromiseRejectionTrackerOperation,
) void {
    // The default implementation of HostPromiseRejectionTracker is to return unused.
}

/// 2.3.1 HostSystemUTCEpochNanoseconds ( global )
/// https://tc39.es/proposal-temporal/#sec-hostsystemutcepochnanoseconds
pub fn hostSystemUTCEpochNanoseconds(agent: *Agent) i96 {
    const io = agent.io;

    // 1. Let ns be the approximate current UTC date and time, in nanoseconds since the epoch.
    const timestamp: std.Io.Timestamp = .now(io, .real);
    const ns = timestamp.toNanoseconds();

    // 2. Return the result of clamping ns between nsMinInstant and nsMaxInstant.
    return std.math.clamp(ns, ns_min_instant, ns_max_instant);
}
