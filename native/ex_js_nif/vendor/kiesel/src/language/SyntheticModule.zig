//! 16.2.1.8 Synthetic Module Records
//! https://tc39.es/ecma262/#sec-synthetic-module-records

const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const language = @import("../language.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

const Agent = execution.Agent;
const Environment = execution.Environment;
const ExecutionContext = execution.ExecutionContext;
const Module = language.Module;
const Realm = execution.Realm;
const ResolvedBindingOrAmbiguous = language.ResolvedBindingOrAmbiguous;
const String = types.String;
const Value = types.Value;
const containsSlice = utils.containsSlice;
const newModuleEnvironment = execution.newModuleEnvironment;
const newPromiseCapability = builtins.newPromiseCapability;
const noexcept = utils.noexcept;
const parseJSON = builtins.parseJSON;
const promiseResolve = builtins.promiseResolve;

const SyntheticModule = @This();

/// [[Realm]]
realm: *Realm,

/// [[Environment]]
environment: ?Environment,

/// [[Namespace]]
namespace: ?*builtins.ModuleNamespace,

/// [[HostDefined]]
host_defined: ?*anyopaque,

/// [[ExportNames]]
export_names: []const []const u8,

/// [[EvaluationSteps]]
evaluation_steps: EvaluationSteps,

pub const EvaluationSteps = struct {
    func: *const fn (module: *SyntheticModule, captures: *anyopaque) Agent.Error!void,
    captures: *anyopaque,
};

/// 16.2.1.8.1 CreateDefaultExportSyntheticModule ( defaultExport )
/// https://tc39.es/ecma262/#sec-create-default-export-synthetic-module
pub fn createDefaultExportSyntheticModule(
    agent: *Agent,
    default_export: Value,
) std.mem.Allocator.Error!*SyntheticModule {
    // 1. Let realm be the current Realm Record.
    const realm = agent.currentRealm();

    const Captures = struct {
        agent: *Agent,
        default_export: Value,
    };
    const captures = try agent.gc_allocator.create(Captures);
    captures.* = .{ .agent = agent, .default_export = default_export };

    // 2. Let setDefaultExport be a new Abstract Closure with parameters (module) that captures
    //    defaultExport and performs the following steps when called:
    const setDefaultExport = struct {
        fn func(
            module: *SyntheticModule,
            captures_ptr: *anyopaque,
        ) Agent.Error!void {
            const captures_: *Captures = @ptrCast(@alignCast(captures_ptr));
            const agent_ = captures_.agent;
            const default_export_ = captures_.default_export;

            // a. Perform SetSyntheticModuleExport(module, "default", defaultExport).
            try module.setSyntheticModuleExport(agent_, "default", default_export_);

            // b. Return NormalCompletion(unused).
        }
    }.func;

    // 3. Return the Synthetic Module Record { [[Realm]]: realm, [[Environment]]: empty,
    //    [[Namespace]]: empty, [[HostDefined]]: undefined, [[ExportNames]]: « "default" »,
    //    [[EvaluationSteps]]: setDefaultExport }.
    const self = try agent.gc_allocator.create(SyntheticModule);
    self.* = .{
        .realm = realm,
        .environment = null,
        .namespace = null,
        .host_defined = null,
        .export_names = &.{"default"},
        .evaluation_steps = .{ .func = setDefaultExport, .captures = captures },
    };
    return self;
}

/// 16.2.1.8.2 ParseJSONModule ( source )
/// https://tc39.es/ecma262/#sec-parse-json-module
pub fn parseJSONModule(agent: *Agent, source: []const u8) Agent.Error!*SyntheticModule {
    // 1. Let parseResult be ? ParseJSON(source).
    const parse_result = try parseJSON(agent, source);

    // 2. Return CreateDefaultExportSyntheticModule(parseResult.[[Value]]).
    return createDefaultExportSyntheticModule(agent, parse_result);
}

/// 16.2.1.8.3 SetSyntheticModuleExport ( module, exportName, exportValue )
/// https://tc39.es/ecma262/#sec-setsyntheticmoduleexport
fn setSyntheticModuleExport(
    self: *SyntheticModule,
    agent: *Agent,
    export_name: []const u8,
    export_value: Value,
) std.mem.Allocator.Error!void {
    // 1. Assert: module.[[ExportNames]] contains exportName.
    std.debug.assert(containsSlice(self.export_names, export_name));

    // 2. Let envRecord be module.[[Environment]].
    // 3. Assert: envRecord is not empty.
    const env = self.environment.?;

    // 4. Perform ! envRecord.SetMutableBinding(exportName, exportValue, true).
    env.setMutableBinding(
        agent,
        try String.fromUtf8(agent, export_name),
        export_value,
        true,
    ) catch |err| try noexcept(err);

    // 5. Return unused.
}

/// 16.2.1.8.4.1 LoadRequestedModules ( [ hostDefined ] )
/// https://tc39.es/ecma262/#sec-smr-LoadRequestedModules
pub fn loadRequestedModules(
    _: *SyntheticModule,
    agent: *Agent,
    _: ?*anyopaque,
) std.mem.Allocator.Error!*builtins.Promise {
    const realm = agent.currentRealm();

    // 1. NOTE: This implementation of LoadRequestedModules does not use hostDefined.

    // 2. Return ! PromiseResolve(%Promise%, undefined).
    const promise = promiseResolve(
        agent,
        try realm.intrinsic(.promise),
        .undefined,
    ) catch |err| try noexcept(err);
    return promise.as(builtins.Promise);
}

/// 16.2.1.8.4.2 GetExportedNames ( [ exportStarSet ] )
/// https://tc39.es/ecma262/#sec-smr-getexportednames
pub fn getExportedNames(
    self: *SyntheticModule,
    agent: *Agent,
    _: ?*Module.ExportStarSet,
) std.mem.Allocator.Error![]const []const u8 {
    // 1. NOTE: This implementation of GetExportedNames does not use exportStarSet.

    // 2. Return module.[[ExportNames]].
    // NOTE: The caller owns the returned memory so we have to dupe this.
    return agent.gc_allocator.dupe([]const u8, self.export_names);
}

/// 16.2.1.8.4.3 ResolveExport ( exportName [ , resolveSet ] )
/// https://tc39.es/ecma262/#sec-smr-resolveexport
pub fn resolveExport(
    self: *SyntheticModule,
    _: *Agent,
    export_name: []const u8,
    _: ?*Module.ResolveSet,
) error{}!?ResolvedBindingOrAmbiguous {
    // 1. NOTE: This implementation of ResolveExport does not use resolveSet.

    // 2. If module.[[ExportNames]] does not contain exportName, return null.
    if (!containsSlice(self.export_names, export_name)) return null;

    // 3. Return ResolvedBinding Record { [[Module]]: module, [[BindingName]]: exportName }.
    return .{
        .resolved_binding = .{
            .module = .{ .synthetic_module = self },
            .binding_name = .{ .string = export_name },
        },
    };
}

/// 16.2.1.8.4.4 Link ( )
/// https://tc39.es/ecma262/#sec-smr-Link
pub fn link(self: *SyntheticModule, agent: *Agent) std.mem.Allocator.Error!void {
    // 1. Let realm be module.[[Realm]].
    const realm = self.realm;

    // 2. Let envRecord be NewModuleEnvironment(realm.[[GlobalEnv]]).
    const env: Environment = .{
        .module_environment = try newModuleEnvironment(agent.gc_allocator, realm.global_env),
    };

    // 3. Set module.[[Environment]] to envRecord.
    self.environment = env;

    // 4. For each String exportName of module.[[ExportNames]], do
    for (self.export_names) |export_name| {
        const name = try String.fromUtf8(agent, export_name);

        // a. Perform ! envRecord.CreateMutableBinding(exportName, false).
        env.createMutableBinding(agent, name, false) catch |err| try noexcept(err);

        // b. Perform ! envRecord.InitializeBinding(exportName, undefined).
        env.initializeBinding(agent, name, .undefined) catch |err| try noexcept(err);
    }

    // 5. Return NormalCompletion(unused).
}

/// 16.2.1.8.4.5 Evaluate ( )
/// https://tc39.es/ecma262/#sec-smr-Evaluate
pub fn evaluate(self: *SyntheticModule, agent: *Agent) std.mem.Allocator.Error!*builtins.Promise {
    const realm = agent.currentRealm();

    // 1. Let moduleContext be a new ECMAScript code execution context.
    var module_context: ExecutionContext = .{
        // 2. Set the Function of moduleContext to null.
        .origin = .module,

        // 3. Set the Realm of moduleContext to module.[[Realm]].
        .realm = self.realm,

        // 4. Set the ScriptOrModule of moduleContext to module.
        .script_or_module = .{ .module = .{ .synthetic_module = self } },

        .ecmascript_code = .{
            // 5. Set the VariableEnvironment of moduleContext to module.[[Environment]].
            .variable_environment = self.environment.?,

            // 6. Set the LexicalEnvironment of moduleContext to module.[[Environment]].
            .lexical_environment = self.environment.?,

            .private_environment = null,
        },
    };

    // 7. Suspend the running execution context.

    // 8. Push moduleContext onto the execution context stack; moduleContext is now the running
    //    execution context.
    try agent.execution_context_stack.append(agent.gc_allocator, &module_context);

    // 9. Let steps be module.[[EvaluationSteps]].
    const steps = self.evaluation_steps;

    // 10. Let result be Completion(steps(module)).
    const result = steps.func(self, steps.captures);

    // 11. Suspend moduleContext and remove it from the execution context stack.
    _ = agent.execution_context_stack.pop().?;

    // 12. Resume the context that is now on the top of the execution context stack as the running
    //     execution context.

    // 13. Let promiseCapability be ! NewPromiseCapability(%Promise%).
    const promise_capability = newPromiseCapability(
        agent,
        Value.from(try realm.intrinsic(.promise)),
    ) catch |err| try noexcept(err);

    // 14. IfAbruptRejectPromise(result, promiseCapability).
    result catch |err| {
        const promise = promise_capability.rejectPromise(agent, err) catch |err_| try noexcept(err_);
        return promise.as(builtins.Promise);
    };

    // 15. Perform ! Call(promiseCapability.[[Resolve]], undefined, « undefined »).
    _ = promise_capability.resolve.call(
        agent,
        .undefined,
        &.{.undefined},
    ) catch |err| try noexcept(err);

    // 16. Return promiseCapability.[[Promise]].
    return promise_capability.promise.as(builtins.Promise);
}

/// 16.2.1.8.5 CreateTextModule ( source )
/// https://tc39.es/proposal-import-text/#sec-create-text-module
pub fn createTextModule(agent: *Agent, source: []const u8) Agent.Error!*SyntheticModule {
    const source_utf8 = try agent.gc_allocator.print("{f}", .{
        std.unicode.fmtUtf8(source),
    });
    const source_string = try String.fromUtf8(agent, source_utf8);

    // 1. Return CreateDefaultExportSyntheticModule(source).
    return createDefaultExportSyntheticModule(agent, Value.from(source_string));
}
