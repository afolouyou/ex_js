//! 16.2.1.7 Source Text Module Records
//! https://tc39.es/ecma262/#sec-source-text-module-records

const std = @import("std");

const ast = @import("ast.zig");
const ast_printing = @import("ast_printing.zig");
const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const interpreter = @import("../interpreter.zig");
const language = @import("../language.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const Environment = execution.Environment;
const ExecutionContext = execution.ExecutionContext;
const GraphLoadingState = language.GraphLoadingState;
const Module = language.Module;
const ModuleRequest = language.ModuleRequest;
const Object = types.Object;
const Parser = language.Parser;
const PromiseCapability = builtins.promise.PromiseCapability;
const Realm = execution.Realm;
const ResolvedBinding = language.ResolvedBinding;
const ResolvedBindingOrAmbiguous = language.ResolvedBindingOrAmbiguous;
const String = types.String;
const Value = types.Value;
const allImportAttributesSupported = language.allImportAttributesSupported;
const asyncBlockStart = builtins.asyncBlockStart;
const containsSlice = utils.containsSlice;
const createBuiltinFunction = builtins.createBuiltinFunction;
const getImportedModule = language.getImportedModule;
const getModuleNamespace = language.getModuleNamespace;
const instantiateAsyncFunctionObject = language.instantiateAsyncFunctionObject;
const instantiateAsyncGeneratorFunctionObject = language.instantiateAsyncGeneratorFunctionObject;
const instantiateGeneratorFunctionObject = language.instantiateGeneratorFunctionObject;
const instantiateOrdinaryFunctionObject = language.instantiateOrdinaryFunctionObject;
const newModuleEnvironment = execution.newModuleEnvironment;
const newPromiseCapability = builtins.newPromiseCapability;
const noexcept = utils.noexcept;
const performPromiseThen = builtins.performPromiseThen;

const SourceTextModule = @This();

/// [[Realm]]
realm: *Realm,

/// [[Environment]]
environment: ?Environment,

/// [[Namespace]]
namespace: ?*builtins.ModuleNamespace,

/// [[ECMAScriptCode]]
ecmascript_code: ast.Module,

/// [[Context]]
context: ?*ExecutionContext,

/// [[ImportMeta]]
import_meta: ?*Object,

/// [[ImportEntries]]
import_entries: std.ArrayList(ImportEntry),

/// [[LocalExportEntries]]
local_export_entries: std.ArrayList(ExportEntry),

/// [[IndirectExportEntries]]
indirect_export_entries: std.ArrayList(ExportEntry),

/// [[StarExportEntries]]
star_export_entries: std.ArrayList(ExportEntry),

/// [[HostDefined]]
host_defined: ?*anyopaque,

/// [[Status]]
status: Status,

/// [[EvaluationError]]
evaluation_error: ?Agent.Exception,

/// [[DFSAncestorIndex]]
dfs_ancestor_index: ?usize,

/// [[RequestedModules]]
requested_modules: std.ArrayList(ModuleRequest),

/// [[LoadedModules]]
loaded_modules: ModuleRequest.HashMap(Module),

/// [[CycleRoot]]
cycle_root: ?*SourceTextModule,

/// [[HasTLA]]
has_tla: bool,

/// [[AsyncEvaluationOrder]]
async_evaluation_order: union(enum) {
    unset,
    done,
    integer: u32,
},

/// [[TopLevelCapability]]
top_level_capability: ?PromiseCapability,

/// [[AsyncParentModules]]
async_parent_modules: std.ArrayList(*SourceTextModule),

/// [[PendingAsyncDependencies]]
pending_async_dependencies: ?usize,

source: []const u8,

const Status = enum {
    new,
    unlinked,
    linking,
    linked,
    evaluating,
    evaluating_async,
    evaluated,
};

/// https://tc39.es/ecma262/#importentry-record
pub const ImportEntry = struct {
    /// [[ModuleRequest]]
    module_request: ModuleRequest,

    /// [[ImportName]]
    import_name: ?union(enum) {
        string: []const u8,
        namespace,
    },

    /// [[LocalName]]
    local_name: []const u8,
};

/// https://tc39.es/ecma262/#exportentry-record
pub const ExportEntry = struct {
    /// [[ExportName]]
    export_name: ?[]const u8,

    /// [[ModuleRequest]]
    module_request: ?ModuleRequest,

    /// [[ImportName]]
    import_name: ?union(enum) {
        string: []const u8,
        namespace,
        all_but_default,
    },

    /// [[LocalName]]
    local_name: ?[]const u8,
};

pub fn print(self: SourceTextModule, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try ast_printing.printModule(self.ecmascript_code, writer, 0);
}

/// 16.2.1.6.1.1 LoadRequestedModules ( [ hostDefined ] )
/// https://tc39.es/ecma262/#sec-LoadRequestedModules
pub fn loadRequestedModules(
    self: *SourceTextModule,
    agent: *Agent,
    host_defined: ?*anyopaque,
) std.mem.Allocator.Error!*builtins.Promise {
    const realm = agent.currentRealm();

    // 1. If hostDefined is not present, set hostDefined to empty.

    // 2. Let promiseCapability be ! NewPromiseCapability(%Promise%).
    const promise_capability = newPromiseCapability(
        agent,
        Value.from(try realm.intrinsic(.promise)),
    ) catch |err| try noexcept(err);

    // 3. Let state be the GraphLoadingState Record { [[IsLoading]]: true,
    //    [[PendingModulesCount]]: 1, [[Visited]]: « », [[PromiseCapability]]: promiseCapability,
    //    [[HostDefined]]: hostDefined }.
    const state = try agent.gc_allocator.create(GraphLoadingState);
    state.* = .{
        .is_loading = true,
        .pending_modules_count = 1,
        .visited = .empty,
        .promise_capability = promise_capability,
        .host_defined = host_defined,
    };

    // 4. Perform InnerModuleLoading(state, module).
    try innerModuleLoading(agent, state, .{ .source_text_module = self });

    // 5. Return promiseCapability.[[Promise]].
    return promise_capability.promise.as(builtins.Promise);
}

/// 16.2.1.6.1.1.1 InnerModuleLoading ( state, module )
/// https://tc39.es/ecma262/#sec-InnerModuleLoading
fn innerModuleLoading(
    agent: *Agent,
    state: *GraphLoadingState,
    module: Module,
) std.mem.Allocator.Error!void {
    // 1. Assert: state.[[IsLoading]] is true.
    std.debug.assert(state.is_loading);

    // 2. If module is a Cyclic Module Record, module.[[Status]] is new, and state.[[Visited]] does
    //    not contain module, then
    if (module == .source_text_module and
        module.source_text_module.status == .new and
        !state.visited.contains(module.source_text_module))
    {
        // a. Append module to state.[[Visited]].
        try state.visited.putNoClobber(agent.gc_allocator, module.source_text_module, {});

        // b. Let requestedModulesCount be the number of elements in module.[[RequestedModules]].
        const requested_modules_count = module.source_text_module.requested_modules.items.len;

        // c. Set state.[[PendingModulesCount]] to
        //    state.[[PendingModulesCount]] + requestedModulesCount.
        state.pending_modules_count += requested_modules_count;

        // d. For each ModuleRequest Record request of module.[[RequestedModules]], do
        for (module.source_text_module.requested_modules.items) |request| {
            // i. If AllImportAttributesSupported(request.[[Attributes]]) is false, then
            if (try allImportAttributesSupported(agent, request.attributes)) |unsupported| {
                // 1. Let error be ThrowCompletion(a newly created SyntaxError object).
                const @"error" = agent.throwException(
                    .syntax_error,
                    "Import attribute '{f}' is not supported",
                    .{unsupported.fmtEscaped()},
                );

                // 2. Perform ContinueModuleLoading(state, error).
                try continueModuleLoading(agent, state, @as(Agent.Error!Module, @"error"));
            }
            // ii. Else if module.[[LoadedModules]] contains a LoadedModuleRequest Record record
            //     such that ModuleRequestsEqual(record, request) is true, then
            else if (module.source_text_module.loaded_modules.get(request)) |loaded_module| {
                // 1. Perform InnerModuleLoading(state, record.[[Module]]).
                try innerModuleLoading(agent, state, loaded_module);
            } else {
                // iii. Else,
                // 1. Perform HostLoadImportedModule(module, request, state.[[HostDefined]], state).
                // 2. NOTE: HostLoadImportedModule will call FinishLoadingImportedModule, which
                //    re-enters the graph loading process through ContinueModuleLoading.
                try agent.host_hooks.hostLoadImportedModule(
                    agent,
                    .{ .module = module.source_text_module },
                    request,
                    state.host_defined,
                    .{ .graph_loading_state = state },
                );
            }

            // iv. If state.[[IsLoading]] is false, return unused.
            if (!state.is_loading) return;
        }
    }

    // 3. Assert: state.[[PendingModulesCount]] ≥ 1.
    std.debug.assert(state.pending_modules_count >= 1);

    // 4. Set state.[[PendingModulesCount]] to state.[[PendingModulesCount]] - 1.
    state.pending_modules_count -= 1;

    // 5. If state.[[PendingModulesCount]] = 0, then
    if (state.pending_modules_count == 0) {
        // a. Set state.[[IsLoading]] to false.
        state.is_loading = false;

        // b. For each Cyclic Module Record loaded of state.[[Visited]], do
        var it = state.visited.keyIterator();
        while (it.next()) |ptr| {
            const loaded = ptr.*;

            // i. If loaded.[[Status]] is new, set loaded.[[Status]] to unlinked.
            if (loaded.status == .new) loaded.status = .unlinked;
        }

        // c. Perform ! Call(state.[[PromiseCapability]].[[Resolve]], undefined, « undefined »).
        _ = state.promise_capability.resolve.call(
            agent,
            .undefined,
            &.{.undefined},
        ) catch |err| try noexcept(err);
    }

    // 6. Return unused.
}

/// 16.2.1.6.1.1.2 ContinueModuleLoading ( state, moduleCompletion )
/// https://tc39.es/ecma262/#sec-ContinueModuleLoading
pub fn continueModuleLoading(
    agent: *Agent,
    state: *GraphLoadingState,
    module_completion: Agent.Error!Module,
) std.mem.Allocator.Error!void {
    // 1. If state.[[IsLoading]] is false, return unused.
    if (!state.is_loading) return;

    // 2. If moduleCompletion is a normal completion, then
    if (module_completion) |module| {
        // a. Perform InnerModuleLoading(state, moduleCompletion.[[Value]]).
        try innerModuleLoading(agent, state, module);
    }
    // 3. Else,
    else |err| switch (err) {
        error.OutOfMemory => |e| return e,

        error.ExceptionThrown => {
            const exception = agent.clearException();

            // a. Set state.[[IsLoading]] to false.
            state.is_loading = false;

            // b. Perform ! Call(state.[[PromiseCapability]].[[Reject]], undefined,
            //    « moduleCompletion.[[Value]] »).
            _ = state.promise_capability.reject.call(
                agent,
                .undefined,
                &.{exception.value},
            ) catch |err_| try noexcept(err_);
        },
    }

    // 4. Return unused.
}

/// 16.2.1.6.1.2 Link ( )
/// https://tc39.es/ecma262/#sec-moduledeclarationlinking
pub fn link(self: *SourceTextModule, agent: *Agent) Agent.Error!void {
    // 1. Assert: module.[[Status]] is one of unlinked, linked, evaluating-async, or evaluated.
    std.debug.assert(switch (self.status) {
        .unlinked, .linked, .evaluating_async, .evaluated => true,
        else => false,
    });

    // 2. Let stack be a new empty List.
    var stack: std.ArrayList(*SourceTextModule) = .empty;
    defer stack.deinit(agent.gc_allocator);

    // 3. Let result be Completion(InnerModuleLinking(module, stack, 0)).
    const result = innerModuleLinking(agent, .{ .source_text_module = self }, &stack, 0);

    // 4. If result is an abrupt completion, then
    _ = result catch |err| {
        // a. For each Cyclic Module Record requiredModule of stack, do
        for (stack.items) |required_module| {
            // i. Assert: requiredModule.[[Status]] is linking.
            std.debug.assert(required_module.status == .linking);

            // ii. Set requiredModule.[[Status]] to unlinked.
            required_module.status = .unlinked;
        }

        // b. Assert: module.[[Status]] is unlinked.
        std.debug.assert(self.status == .unlinked);

        // c. Return ? result.
        return err;
    };

    // 5. Assert: module.[[Status]] is one of linked, evaluating-async, or evaluated.
    std.debug.assert(switch (self.status) {
        .linked, .evaluating_async, .evaluated => true,
        else => false,
    });

    // 6. Assert: stack is empty.
    std.debug.assert(stack.items.len == 0);

    // 7. Return unused.
}

/// 16.2.1.6.1.2.1 InnerModuleLinking ( module, stack, index )
/// https://tc39.es/ecma262/#sec-InnerModuleLinking
fn innerModuleLinking(
    agent: *Agent,
    abstract_module: Module,
    stack: *std.ArrayList(*SourceTextModule),
    index: usize,
) Agent.Error!usize {
    // 1. If module is not a Cyclic Module Record, then
    if (abstract_module != .source_text_module) {
        // a. Perform ? module.Link().
        try abstract_module.link(agent);

        // b. Return index.
        return index;
    }

    const module = abstract_module.source_text_module;

    // 2. If module.[[Status]] is one of linking, linked, evaluating-async, or evaluated, then
    if (switch (module.status) {
        .linking, .linked, .evaluating_async, .evaluated => true,
        else => false,
    }) {
        // a. Return index.
        return index;
    }

    // 3. Assert: module.[[Status]] is unlinked.
    std.debug.assert(module.status == .unlinked);

    // 4. Set module.[[Status]] to linking.
    module.status = .linking;

    // 5. Let moduleIndex be index.
    const module_index = index;

    // 6. Set module.[[DFSAncestorIndex]] to index.
    module.dfs_ancestor_index = index;

    // 7. Set index to index + 1.
    var new_index = index + 1;

    // 8. Append module to stack.
    try stack.append(agent.gc_allocator, module);

    // 9. For each ModuleRequest Record request of module.[[RequestedModules]], do
    for (module.requested_modules.items) |request| {
        // a. Let requiredModule be GetImportedModule(module, request).
        const abstract_required_module = getImportedModule(module, request);

        // b. Set index to ? InnerModuleLinking(requiredModule, stack, index).
        new_index = try innerModuleLinking(agent, abstract_required_module, stack, new_index);

        // c. If requiredModule is a Cyclic Module Record, then
        if (abstract_required_module == .source_text_module) {
            const required_module = abstract_required_module.source_text_module;

            // i. Assert: requiredModule.[[Status]] is one of linking, linked, evaluating-async, or
            //    evaluated.
            std.debug.assert(switch (required_module.status) {
                .linking, .linked, .evaluating_async, .evaluated => true,
                else => false,
            });

            // ii. Assert: requiredModule.[[Status]] is linking if and only if stack contains
            //     requiredModule.
            std.debug.assert((required_module.status == .linking) ==
                (std.mem.findScalar(*SourceTextModule, stack.items, required_module) != null));

            // iii. If requiredModule.[[Status]] is linking, then
            if (required_module.status == .linking) {
                // 1. Set module.[[DFSAncestorIndex]] to min(module.[[DFSAncestorIndex]],
                //    requiredModule.[[DFSAncestorIndex]]).
                module.dfs_ancestor_index = @min(
                    module.dfs_ancestor_index.?,
                    required_module.dfs_ancestor_index.?,
                );
            }
        }
    }

    // 10. Perform ? module.InitializeEnvironment().
    try module.initializeEnvironment(agent);

    // 11. Assert: module occurs exactly once in stack.

    // 12. Assert: module.[[DFSAncestorIndex]] ≤ moduleIndex.
    std.debug.assert(module.dfs_ancestor_index.? <= module_index);

    // 13. If module.[[DFSAncestorIndex]] = moduleIndex, then
    if (module.dfs_ancestor_index.? == module_index) {
        // a. Let done be false.
        // b. Repeat, while done is false,
        while (true) {
            // i. Let requiredModule be the last element of stack.
            // ii. Remove the last element of stack.
            // iii. Assert: requiredModule is a Cyclic Module Record.
            const required_module = stack.pop().?;

            // iv. Set requiredModule.[[Status]] to linked.
            required_module.status = .linked;

            // v. If requiredModule and module are the same Module Record, set done to true.
            if (required_module == module) break;
        }
    }

    // 14. Return index.
    return new_index;
}

/// 16.2.1.7.1 ParseModule ( sourceText, realm, hostDefined )
/// https://tc39.es/ecma262/#sec-parsemodule
pub fn parse(
    source_text: []const u8,
    realm: *Realm,
    host_defined: ?*anyopaque,
    options: Parser.Options,
) Parser.Error!*SourceTextModule {
    const agent = realm.agent;

    const source = try agent.gc_allocator.dupeSentinel(u8, source_text, 0);

    // 1. Let body be ParseText(sourceText, Module).
    // 2. If body is a List of errors, return body.
    const body = try Parser.parse(ast.Module, agent.gc_allocator, source, options);

    // 3. Let requestedModules be the ModuleRequests of body.
    var requested_modules: std.ArrayList(ModuleRequest) = .empty;
    {
        const tmp = try body.moduleRequests(agent.gc_allocator);
        defer agent.gc_allocator.free(tmp);
        try requested_modules.appendSlice(agent.gc_allocator, tmp);
    }

    // 4. Let importEntries be the ImportEntries of body.
    var import_entries: std.ArrayList(ImportEntry) = .empty;
    try body.collectImportEntries(agent.gc_allocator, &import_entries);

    // 5. Let importedBoundNames be ImportedLocalNames(importEntries).
    // NOTE: This is lazily done with a for loop below.

    // 6. Let indirectExportEntries be a new empty List.
    var indirect_export_entries: std.ArrayList(ExportEntry) = .empty;

    // 7. Let localExportEntries be a new empty List.
    var local_export_entries: std.ArrayList(ExportEntry) = .empty;

    // 8. Let starExportEntries be a new empty List.
    var star_export_entries: std.ArrayList(ExportEntry) = .empty;

    // 9. Let exportEntries be the ExportEntries of body.
    var export_entries: std.ArrayList(ExportEntry) = .empty;
    defer export_entries.deinit(agent.gc_allocator);
    try body.collectExportEntries(agent.gc_allocator, &export_entries);

    // 10. For each ExportEntry Record exportEntry of exportEntries, do
    for (export_entries.items) |export_entry| {
        // a. If exportEntry.[[ModuleRequest]] is null, then
        if (export_entry.module_request == null) {
            const import_entry_with_bound_name: ?ImportEntry = for (import_entries.items) |import_entry| {
                if (export_entry.local_name != null and
                    std.mem.eql(u8, import_entry.local_name, export_entry.local_name.?))
                    break import_entry;
            } else null;

            // i. If importedBoundNames does not contain exportEntry.[[LocalName]], then
            if (import_entry_with_bound_name == null) {
                // 1. Append exportEntry to localExportEntries.
                try local_export_entries.append(agent.gc_allocator, export_entry);
            } else {
                // ii. Else,
                // 1. NOTE: When exporting a binding or namespace object which was originally
                //    imported from another module, the ExportEntry Record is rewritten to match the
                //    form it would have if the binding or namespace object had been re-exported
                //    directly from the original module rather than imported then exported. This
                //    allows conflicts which arise from exporting the same binding or namespace
                //    twice under the same name through `export * from` to be ignored rather than
                //    being treated as ambiguous in step 9.e.iii of the ResolveExport concrete
                //    method of Source Text Module Records.
                // 2. Let importEntry be the element of importEntries whose [[LocalName]] is
                //    exportEntry.[[LocalName]].
                const import_entry = import_entry_with_bound_name.?;

                // 3. Append the ExportEntry Record {
                //    [[ModuleRequest]]: importEntry.[[ModuleRequest]],
                //    [[ImportName]]: importEntry.[[ImportName]], [[LocalName]]: null,
                //    [[ExportName]]: exportEntry.[[ExportName]] } to indirectExportEntries.
                try indirect_export_entries.append(agent.gc_allocator, .{
                    .module_request = import_entry.module_request,
                    .import_name = if (import_entry.import_name) |import_name|
                        switch (import_name) {
                            .string => |string| .{ .string = string },
                            .namespace => .namespace,
                        }
                    else
                        null,
                    .local_name = null,
                    .export_name = export_entry.export_name,
                });
            }
        }
        // b. Else if exportEntry.[[ImportName]] is all-but-default, then
        else if (export_entry.import_name != null and export_entry.import_name.? == .all_but_default) {
            // i. Assert: exportEntry.[[ExportName]] is null.
            std.debug.assert(export_entry.export_name == null);

            // ii. Append exportEntry to starExportEntries.
            try star_export_entries.append(agent.gc_allocator, export_entry);
        } else {
            // c. Else,
            // i. Append exportEntry to indirectExportEntries.
            try indirect_export_entries.append(agent.gc_allocator, export_entry);
        }
    }

    // 11. Let async be body Contains `await`.
    const async = body.hasTla();

    // 12. Return Source Text Module Record { [[Realm]]: realm, [[Environment]]: empty,
    //     [[Namespace]]: empty, [[CycleRoot]]: empty, [[HasTLA]]: async,
    //     [[AsyncEvaluationOrder]]: unset, [[TopLevelCapability]]: empty,
    //     [[AsyncParentModules]]: « », [[PendingAsyncDependencies]]: empty, [[Status]]: new,
    //     [[EvaluationError]]: empty, [[HostDefined]]: hostDefined, [[ECMAScriptCode]]: body,
    //     [[Context]]: empty, [[ImportMeta]]: empty, [[RequestedModules]]: requestedModules,
    //     [[LoadedModules]]: « », [[ImportEntries]]: importEntries,
    //     [[LocalExportEntries]]: localExportEntries,
    //     [[IndirectExportEntries]]: indirectExportEntries,
    //     [[StarExportEntries]]: starExportEntries, [[DFSAncestorIndex]]: empty }.
    const self = try agent.gc_allocator.create(SourceTextModule);
    self.* = .{
        .realm = realm,
        .environment = null,
        .namespace = null,
        .cycle_root = null,
        .has_tla = async,
        .async_evaluation_order = .unset,
        .top_level_capability = null,
        .async_parent_modules = .empty,
        .pending_async_dependencies = null,
        .status = .new,
        .evaluation_error = null,
        .host_defined = host_defined,
        .ecmascript_code = body,
        .context = null,
        .import_meta = null,
        .requested_modules = requested_modules,
        .import_entries = import_entries,
        .local_export_entries = local_export_entries,
        .indirect_export_entries = indirect_export_entries,
        .star_export_entries = star_export_entries,
        .loaded_modules = .empty,
        .dfs_ancestor_index = null,
        .source = source,
    };
    return self;
}

/// 16.2.1.6.1.3 Evaluate ( )
/// https://tc39.es/ecma262/#sec-moduleevaluation
pub fn evaluate(module_arg: *SourceTextModule, agent: *Agent) std.mem.Allocator.Error!*builtins.Promise {
    const realm = agent.currentRealm();
    var module = module_arg;

    // TODO: 1. Assert: This call to Evaluate is not happening at the same time as another call to
    //          Evaluate within the surrounding agent.

    // 2. Assert: module.[[Status]] is one of linked, evaluating-async, or evaluated.
    std.debug.assert(switch (module.status) {
        .linked, .evaluating_async, .evaluated => true,
        else => false,
    });

    // 3. If module.[[Status]] is either evaluating-async or evaluated, then
    if (module.status == .evaluating_async or module.status == .evaluated) {
        // a. If module.[[CycleRoot]] is not empty, then
        if (module.cycle_root) |cycle_root| {
            // i. Set module to module.[[CycleRoot]].
            module = cycle_root;
        } else {
            // b. Else,
            // i. Assert: module.[[Status]] is evaluated and module.[[EvaluationError]] is a throw
            //    completion.
            std.debug.assert(module.status == .evaluated);
            std.debug.assert(module.evaluation_error != null);
        }
    }

    // 4. If module.[[TopLevelCapability]] is not empty, then
    if (module.top_level_capability) |top_level_capability| {
        // a. Return module.[[TopLevelCapability]].[[Promise]].
        return top_level_capability.promise.as(builtins.Promise);
    }

    // 5. Let stack be a new empty List.
    var stack: std.ArrayList(*SourceTextModule) = .empty;
    defer stack.deinit(agent.gc_allocator);

    // 6. Let promiseCapability be ! NewPromiseCapability(%Promise%).
    const promise_capability = newPromiseCapability(
        agent,
        Value.from(try realm.intrinsic(.promise)),
    ) catch |err| try noexcept(err);

    // 7. Set module.[[TopLevelCapability]] to promiseCapability.
    module.top_level_capability = promise_capability;

    // 8. Let result be Completion(InnerModuleEvaluation(module, stack, 0)).
    const result = innerModuleEvaluation(agent, .{ .source_text_module = module }, &stack, 0);

    // 9. If result is an abrupt completion, then
    if (std.meta.isError(result)) _ = result catch |err| switch (err) {
        error.OutOfMemory => |e| return e,

        error.ExceptionThrown => {
            const exception = agent.clearException();

            // a. For each Cyclic Module Record requiredModule of stack, do
            for (stack.items) |required_module| {
                // i. Assert: requiredModule.[[Status]] is evaluating.
                std.debug.assert(required_module.status == .evaluating);

                // ii. Set requiredModule.[[Status]] to evaluated.
                required_module.status = .evaluated;

                // iii. Set requiredModule.[[EvaluationError]] to result.
                required_module.evaluation_error = exception;
            }

            // b. Assert: module.[[Status]] is evaluated.
            std.debug.assert(module.status == .evaluated);

            // c. Assert: module.[[EvaluationError]] and result are the same Completion Record.

            // d. Perform ! Call(promiseCapability.[[Reject]], undefined, « result.[[Value]] »).
            _ = promise_capability.reject.call(
                agent,
                .undefined,
                &.{exception.value},
            ) catch |err_| try noexcept(err_);
        },
    } else {
        // 10. Else,
        // a. Assert: module.[[Status]] is either evaluating-async or evaluated.
        std.debug.assert(switch (module.status) {
            .evaluating_async, .evaluated => true,
            else => false,
        });

        // b. Assert: module.[[EvaluationError]] is empty.
        std.debug.assert(module.evaluation_error == null);

        // c. If module.[[Status]] is evaluated, then
        if (module.status == .evaluated) {
            // i. Assert: module.[[AsyncEvaluationOrder]] is either unset or done.
            // ii. NOTE: module.[[AsyncEvaluationOrder]] is done if and only if module had already
            //     been evaluated and that evaluation was asynchronous.
            std.debug.assert(switch (module.async_evaluation_order) {
                .unset, .done => true,
                else => false,
            });

            // iii. Perform ! Call(promiseCapability.[[Resolve]], undefined, « undefined »).
            _ = promise_capability.resolve.call(
                agent,
                .undefined,
                &.{.undefined},
            ) catch |err| try noexcept(err);
        }

        // d. Assert: stack is empty.
        std.debug.assert(stack.items.len == 0);
    }

    // Ensures the promise returned by an async module is resolved
    agent.drainJobQueue();

    // 11. Return promiseCapability.[[Promise]].
    return promise_capability.promise.as(builtins.Promise);
}

/// 16.2.1.6.1.3.1 InnerModuleEvaluation ( module, stack, index )
/// https://tc39.es/ecma262/#sec-innermoduleevaluation
fn innerModuleEvaluation(
    agent: *Agent,
    abstract_module: Module,
    stack: *std.ArrayList(*SourceTextModule),
    index: usize,
) Agent.Error!usize {
    // 1. If module is not a Cyclic Module Record, then
    if (abstract_module != .source_text_module) {
        // a. Perform ? EvaluateModuleSync(module).
        try abstract_module.evaluateSync(agent);

        // b. Return index.
        return index;
    }

    const module = abstract_module.source_text_module;

    // 2. If module.[[Status]] is either evaluating-async or evaluated, then
    if (switch (module.status) {
        .evaluating_async, .evaluated => true,
        else => false,
    }) {
        // a. If module.[[EvaluationError]] is empty, return index.
        // b. Return ? module.[[EvaluationError]].
        agent.exception = module.evaluation_error orelse return index;
        return error.ExceptionThrown;
    }

    // 3. If module.[[Status]] is evaluating, return index.
    if (module.status == .evaluating) return index;

    // 4. Assert: module.[[Status]] is linked.
    std.debug.assert(module.status == .linked);

    // 5. Set module.[[Status]] to evaluating.
    module.status = .evaluating;

    // 6. Let moduleIndex be index.
    const module_index = index;

    // 7. Set module.[[DFSAncestorIndex]] to index.
    module.dfs_ancestor_index = index;

    // 8. Set module.[[PendingAsyncDependencies]] to 0.
    module.pending_async_dependencies = 0;

    // 9. Set index to index + 1.
    var new_index = index + 1;

    // 10. Append module to stack.
    try stack.append(agent.gc_allocator, module);

    // 11. For each ModuleRequest Record request of module.[[RequestedModules]], do
    for (module.requested_modules.items) |request| {
        // a. Let requiredModule be GetImportedModule(module, request).
        const abstract_required_module = getImportedModule(module, request);

        // b. Set index to ? InnerModuleEvaluation(requiredModule, stack, index).
        new_index = try innerModuleEvaluation(agent, abstract_required_module, stack, new_index);

        // c. If requiredModule is a Cyclic Module Record, then
        if (abstract_required_module == .source_text_module) {
            var required_module = abstract_required_module.source_text_module;

            // i. Assert: requiredModule.[[Status]] is one of evaluating, evaluating-async, or
            //    evaluated.
            std.debug.assert(switch (required_module.status) {
                .evaluating, .evaluating_async, .evaluated => true,
                else => false,
            });

            // ii. Assert: requiredModule.[[Status]] is evaluating if and only if stack contains
            //     requiredModule.
            std.debug.assert((required_module.status == .evaluating) ==
                (std.mem.findScalar(*SourceTextModule, stack.items, required_module) != null));

            // iii. If requiredModule.[[Status]] is evaluating, then
            if (required_module.status == .evaluating) {
                // 1. Set module.[[DFSAncestorIndex]] to min(module.[[DFSAncestorIndex]],
                //    requiredModule.[[DFSAncestorIndex]]).
                module.dfs_ancestor_index = @min(
                    module.dfs_ancestor_index.?,
                    required_module.dfs_ancestor_index.?,
                );
            } else {
                // iv. Else,
                // 1. Set requiredModule to requiredModule.[[CycleRoot]].
                required_module = required_module.cycle_root.?;

                // 2. Assert: requiredModule.[[Status]] is either evaluating-async or evaluated.
                std.debug.assert(switch (required_module.status) {
                    .evaluating_async, .evaluated => true,
                    else => false,
                });

                // 3. If requiredModule.[[EvaluationError]] is not empty, return
                //    ? requiredModule.[[EvaluationError]].
                if (required_module.evaluation_error) |evaluation_error| {
                    agent.exception = evaluation_error;
                    return error.ExceptionThrown;
                }
            }

            // v. If requiredModule.[[AsyncEvaluationOrder]] is an integer, then
            if (required_module.async_evaluation_order == .integer) {
                // 1. Set module.[[PendingAsyncDependencies]] to
                //    module.[[PendingAsyncDependencies]] + 1.
                module.pending_async_dependencies.? += 1;

                // 2. Append module to requiredModule.[[AsyncParentModules]].
                try required_module.async_parent_modules.append(agent.gc_allocator, module);
            }
        }
    }

    // 12. If module.[[HasTLA]] is true or module.[[PendingAsyncDependencies]] > 0, then
    if (module.has_tla or module.pending_async_dependencies.? > 0) {
        // a. Assert: module.[[AsyncEvaluationOrder]] is unset.
        std.debug.assert(module.async_evaluation_order == .unset);

        // b. Set module.[[AsyncEvaluationOrder]] to IncrementModuleAsyncEvaluationCount().
        module.async_evaluation_order = .{ .integer = agent.incrementModuleAsyncEvaluationCount() };

        // c. If module.[[PendingAsyncDependencies]] = 0, perform ExecuteAsyncModule(module).
        if (module.pending_async_dependencies.? == 0) {
            try executeAsyncModule(agent, module);
        }
    } else {
        // 13. Else,
        // a. Perform ? module.ExecuteModule().
        try module.executeModule(agent, null);
    }

    // 14. Assert: module occurs exactly once in stack.

    // 15. Assert: module.[[DFSAncestorIndex]] ≤ moduleIndex.
    std.debug.assert(module.dfs_ancestor_index.? <= module_index);

    // 16. If module.[[DFSAncestorIndex]] = moduleIndex, then
    if (module.dfs_ancestor_index == module_index) {
        // a. Let done be false.
        // b. Repeat, while done is false,
        while (true) {
            // i. Let requiredModule be the last element of stack.
            // ii. Remove the last element of stack.
            // iii. Assert: requiredModule is a Cyclic Module Record.
            const required_module = stack.pop().?;

            // iv. Assert: requiredModule.[[AsyncEvaluationOrder]] is either an integer or unset.
            std.debug.assert(required_module.async_evaluation_order == .integer or
                required_module.async_evaluation_order == .unset);

            // v. If requiredModule.[[AsyncEvaluationOrder]] is unset, set requiredModule.[[Status]]
            //    to evaluated.
            // vi. Else, set requiredModule.[[Status]] to evaluating-async.
            required_module.status = if (required_module.async_evaluation_order == .unset) .evaluated else .evaluating_async;

            // viii. Set requiredModule.[[CycleRoot]] to module.
            required_module.cycle_root = module;

            // vii. If requiredModule and module are the same Module Record, set done to true.
            if (required_module == module) break;
        }
    }

    // 17. Return index.
    return new_index;
}

/// 16.2.1.6.1.3.2 ExecuteAsyncModule ( module )
/// https://tc39.es/ecma262/#sec-execute-async-module
fn executeAsyncModule(agent: *Agent, module: *SourceTextModule) std.mem.Allocator.Error!void {
    const realm = agent.currentRealm();

    // 1. Assert: module.[[Status]] is either evaluating or evaluating-async.
    std.debug.assert(module.status == .evaluating or module.status == .evaluating_async);

    // 2. Assert: module.[[HasTLA]] is true.
    std.debug.assert(module.has_tla);

    // 3. Let promiseCapability be ! NewPromiseCapability(%Promise%).
    const promise_capability = newPromiseCapability(
        agent,
        Value.from(try realm.intrinsic(.promise)),
    ) catch |err| try noexcept(err);

    const Captures = struct {
        module: *SourceTextModule,
    };
    const captures = try agent.gc_allocator.create(Captures);
    captures.* = .{ .module = module };

    // 4. Let fulfilledClosure be a new Abstract Closure with no parameters that captures module and
    //    performs the following steps when called:
    const fulfilled_closure = struct {
        fn func(agent_: *Agent, _: Value, _: Arguments) Agent.Error!Value {
            const function = agent_.activeFunctionObject();
            const captures_ = function.as(builtins.BuiltinFunction).fields.additionalFieldsAs(Captures);
            const module_ = captures_.module;

            // a. Perform AsyncModuleExecutionFulfilled(module).
            try asyncModuleExecutionFulfilled(agent_, module_);

            // b. Return NormalCompletion(undefined).
            return .undefined;
        }
    }.func;

    // 5. Let onFulfilled be CreateBuiltinFunction(fulfilledClosure, 0, "", « »).
    const on_fulfilled = try createBuiltinFunction(
        agent,
        .{ .function = fulfilled_closure },
        0,
        "",
        .{ .additional_fields = captures },
    );

    // 6. Let rejectedClosure be a new Abstract Closure with parameters (error) that captures module
    //    and performs the following steps when called:
    const rejected_closure = struct {
        fn func(agent_: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
            const function = agent_.activeFunctionObject();
            const captures_ = function.as(builtins.BuiltinFunction).fields.additionalFieldsAs(Captures);
            const module_ = captures_.module;
            const @"error" = arguments.get(0);

            // a. Perform AsyncModuleExecutionRejected(module, error).
            try asyncModuleExecutionRejected(agent_, module_, .{
                .value = @"error",
                .stack_trace = try agent_.captureStackTrace(.{}),
            });

            // b. Return NormalCompletion(undefined).
            return .undefined;
        }
    }.func;

    // 7. Let onRejected be CreateBuiltinFunction(rejectedClosure, 0, "", « »).
    const on_rejected = try createBuiltinFunction(
        agent,
        .{ .function = rejected_closure },
        0,
        "",
        .{ .additional_fields = captures },
    );

    // 8. Perform PerformPromiseThen(promiseCapability.[[Promise]], onFulfilled, onRejected).
    _ = try performPromiseThen(
        agent,
        promise_capability.promise.as(builtins.Promise),
        Value.from(&on_fulfilled.object),
        Value.from(&on_rejected.object),
        null,
    );

    // 9. Perform ! module.ExecuteModule(promiseCapability).
    module.executeModule(agent, promise_capability) catch |err| try noexcept(err);

    // 10. Return unused.
}

/// 16.2.1.6.1.3.3 GatherAvailableAncestors ( module, execList )
/// https://tc39.es/ecma262/#sec-gather-available-ancestors
fn gatherAvailableAncestors(
    agent: *Agent,
    module: *SourceTextModule,
    exec_list: *std.ArrayList(*SourceTextModule),
) std.mem.Allocator.Error!void {
    // 1. For each Cyclic Module Record ancestorModule of module.[[AsyncParentModules]], do
    for (module.async_parent_modules.items) |ancestor_module| {
        // a. If execList does not contain ancestorModule and
        //    ancestorModule.[[CycleRoot]].[[EvaluationError]] is empty, then
        if (std.mem.findScalar(*SourceTextModule, exec_list.items, ancestor_module) == null and
            ancestor_module.cycle_root.?.evaluation_error == null)
        {
            // i. Assert: ancestorModule.[[Status]] is evaluating-async.
            std.debug.assert(ancestor_module.status == .evaluating_async);

            // ii. Assert: ancestorModule.[[EvaluationError]] is empty.
            std.debug.assert(ancestor_module.evaluation_error == null);

            // iii. Assert: ancestorModule.[[AsyncEvaluationOrder]] is an integer.
            std.debug.assert(ancestor_module.async_evaluation_order == .integer);

            // iv. Assert: ancestorModule.[[PendingAsyncDependencies]] > 0.
            std.debug.assert(ancestor_module.pending_async_dependencies.? > 0);

            // v. Set ancestorModule.[[PendingAsyncDependencies]] to
            //    ancestorModule.[[PendingAsyncDependencies]] - 1.
            ancestor_module.pending_async_dependencies.? -= 1;

            // vi. If ancestorModule.[[PendingAsyncDependencies]] = 0, then
            if (ancestor_module.pending_async_dependencies.? == 0) {
                // 1. Append ancestorModule to execList.
                try exec_list.append(agent.gc_allocator, ancestor_module);

                // 2. If ancestorModule.[[HasTLA]] is false, perform GatherAvailableAncestors(
                //    ancestorModule, execList).
                if (!ancestor_module.has_tla) {
                    try gatherAvailableAncestors(agent, ancestor_module, exec_list);
                }
            }
        }
    }

    // 2. Return unused.
}

/// 16.2.1.6.1.3.4 AsyncModuleExecutionFulfilled ( module )
/// https://tc39.es/ecma262/#sec-async-module-execution-fulfilled
fn asyncModuleExecutionFulfilled(
    agent: *Agent,
    module: *SourceTextModule,
) std.mem.Allocator.Error!void {
    // 1. If module.[[Status]] is evaluated, then
    if (module.status == .evaluated) {
        // a. Assert: module.[[EvaluationError]] is not empty.
        std.debug.assert(module.evaluation_error != null);

        // b. Return unused.
        return;
    }

    // 2. Assert: module.[[Status]] is evaluating-async.
    std.debug.assert(module.status == .evaluating_async);

    // 3. Assert: module.[[AsyncEvaluationOrder]] is an integer.
    std.debug.assert(module.async_evaluation_order == .integer);

    // 4. Assert: module.[[EvaluationError]] is empty.
    std.debug.assert(module.evaluation_error == null);

    // 5. Set module.[[AsyncEvaluationOrder]] to done.
    module.async_evaluation_order = .done;

    // 6. Set module.[[Status]] to evaluated.
    module.status = .evaluated;

    // 7. If module.[[TopLevelCapability]] is not empty, then
    if (module.top_level_capability) |top_level_capability| {
        // a. Assert: module.[[CycleRoot]] and module are the same Module Record.
        std.debug.assert(module.cycle_root == module);

        // b. Perform ! Call(module.[[TopLevelCapability]].[[Resolve]], undefined, « undefined »).
        _ = top_level_capability.resolve.call(
            agent,
            .undefined,
            &.{.undefined},
        ) catch |err| try noexcept(err);
    }

    // 8. Let execList be a new empty List.
    var exec_list: std.ArrayList(*SourceTextModule) = .empty;
    defer exec_list.deinit(agent.gc_allocator);

    // 9. Perform GatherAvailableAncestors(module, execList).
    try gatherAvailableAncestors(agent, module, &exec_list);

    // 10. Assert: All elements of execList have their [[AsyncEvaluationOrder]] field set to an
    //     integer, [[PendingAsyncDependencies]] field set to 0, and [[EvaluationError]] field set
    //     to empty.
    for (exec_list.items) |m| {
        std.debug.assert(m.async_evaluation_order == .integer);
        std.debug.assert(m.pending_async_dependencies == 0);
        std.debug.assert(m.evaluation_error == null);
    }

    // 11. Let sortedExecList be a List whose elements are the elements of execList, sorted by their
    //     [[AsyncEvaluationOrder]] field in ascending order.
    std.mem.sort(*SourceTextModule, exec_list.items, {}, struct {
        fn lessThanFn(_: void, lhs: *SourceTextModule, rhs: *SourceTextModule) bool {
            return lhs.async_evaluation_order.integer < rhs.async_evaluation_order.integer;
        }
    }.lessThanFn);

    // 12. For each Cyclic Module Record ancestorModule of sortedExecList, do
    for (exec_list.items) |ancestor_module| {
        // a. If ancestorModule.[[Status]] is evaluated, then
        if (ancestor_module.status == .evaluated) {
            // i. Assert: ancestorModule.[[EvaluationError]] is not empty.
            std.debug.assert(ancestor_module.evaluation_error != null);
        }
        // b. Else if ancestorModule.[[HasTLA]] is true, then
        else if (ancestor_module.has_tla) {
            // i. Perform ExecuteAsyncModule(ancestorModule).
            try executeAsyncModule(agent, ancestor_module);
        } else {
            // c. Else,
            // i. Let result be Completion(ancestorModule.ExecuteModule()).
            const result = ancestor_module.executeModule(agent, null);

            // ii. If result is an abrupt completion, then
            _ = result catch |err| switch (err) {
                error.OutOfMemory => |e| return e,

                error.ExceptionThrown => {
                    const exception = agent.clearException();

                    // 1. Perform AsyncModuleExecutionRejected(ancestorModule, result.[[Value]]).
                    try asyncModuleExecutionRejected(agent, ancestor_module, exception);
                },
            };
            // iii. Else,

            // 1. Set ancestorModule.[[AsyncEvaluationOrder]] to done.
            ancestor_module.async_evaluation_order = .done;

            // 2. Set ancestorModule.[[Status]] to evaluated.
            ancestor_module.status = .evaluated;

            // 3. If ancestorModule.[[TopLevelCapability]] is not empty, then
            if (ancestor_module.top_level_capability) |top_level_capability| {
                // a. Assert: ancestorModule.[[CycleRoot]] and ancestorModule are the same Module
                //    Record.
                std.debug.assert(ancestor_module.cycle_root == ancestor_module);

                // b. Perform ! Call(ancestorModule.[[TopLevelCapability]].[[Resolve]], undefined,
                //    « undefined »).
                _ = top_level_capability.resolve.call(
                    agent,
                    .undefined,
                    &.{.undefined},
                ) catch |err| try noexcept(err);
            }
        }
    }

    // 13. Return unused.
}

/// 16.2.1.6.1.3.5 AsyncModuleExecutionRejected ( module, error )
/// https://tc39.es/ecma262/#sec-async-module-execution-rejected
fn asyncModuleExecutionRejected(
    agent: *Agent,
    module: *SourceTextModule,
    @"error": Agent.Exception,
) std.mem.Allocator.Error!void {
    // 1. If module.[[Status]] is evaluated, then
    if (module.status == .evaluated) {
        // a. Assert: module.[[EvaluationError]] is not empty.
        std.debug.assert(module.evaluation_error != null);

        // b. Return unused.
        return;
    }

    // 2. Assert: module.[[Status]] is evaluating-async.
    std.debug.assert(module.status == .evaluating_async);

    // 3. Assert: module.[[AsyncEvaluationOrder]] is an integer.
    std.debug.assert(module.async_evaluation_order == .integer);

    // 4. Assert: module.[[EvaluationError]] is empty.
    std.debug.assert(module.evaluation_error == null);

    // 5. Set module.[[EvaluationError]] to ThrowCompletion(error).
    module.evaluation_error = @"error";

    // 6. Set module.[[Status]] to evaluated.
    module.status = .evaluated;

    // 7. Set module.[[AsyncEvaluationOrder]] to done.
    // 8. NOTE: module.[[AsyncEvaluationOrder]] is set to done for symmetry with
    //    AsyncModuleExecutionFulfilled. In InnerModuleEvaluation, the value of a module's
    //    [[AsyncEvaluationOrder]] internal slot is unused when its [[EvaluationError]] internal
    //    slot is not empty.
    module.async_evaluation_order = .done;

    // 9. If module.[[TopLevelCapability]] is not empty, then
    if (module.top_level_capability) |top_level_capability| {
        // a. Assert: module.[[CycleRoot]] and module are the same Module Record.
        std.debug.assert(module.cycle_root == module);

        // b. Perform ! Call(module.[[TopLevelCapability]].[[Reject]], undefined, « error »).
        _ = top_level_capability.reject.call(
            agent,
            .undefined,
            &.{@"error".value},
        ) catch |err| try noexcept(err);
    }

    // 10. For each Cyclic Module Record ancestorModule of module.[[AsyncParentModules]], do
    for (module.async_parent_modules.items) |ancestor_module| {
        // a. Perform AsyncModuleExecutionRejected(ancestorModule, error).
        try asyncModuleExecutionRejected(agent, ancestor_module, @"error");
    }

    // 11. Return unused.
}

/// 16.2.1.7.2.1 GetExportedNames ( [ exportStarSet ] )
/// https://tc39.es/ecma262/#sec-getexportednames
pub fn getExportedNames(
    self: *const SourceTextModule,
    agent: *Agent,
    maybe_export_star_set: ?*Module.ExportStarSet,
) std.mem.Allocator.Error![]const []const u8 {
    // 1. Assert: module.[[Status]] is not new.
    std.debug.assert(self.status != .new);

    // 2. If exportStarSet is not present, set exportStarSet to a new empty List.
    var new_export_star_set: Module.ExportStarSet = undefined;
    defer if (maybe_export_star_set == null) new_export_star_set.deinit(agent.gc_allocator);
    var export_star_set = maybe_export_star_set orelse blk: {
        new_export_star_set = .empty;
        break :blk &new_export_star_set;
    };

    const export_star_set_key: @FieldType(Module.ExportStarSet.KV, "key") = self;

    // 3. If exportStarSet contains module, then
    if (export_star_set.contains(export_star_set_key)) {
        // a. Assert: We've reached the starting point of an `export *` circularity.
        // b. Return a new empty List.
        return &.{};
    }

    // 4. Append module to exportStarSet.
    try export_star_set.putNoClobber(agent.gc_allocator, export_star_set_key, {});

    // 5. Let exportedNames be a new empty List.
    var exported_names: std.ArrayList([]const u8) = .empty;

    // 6. For each ExportEntry Record exportEntry of module.[[LocalExportEntries]], do
    for (self.local_export_entries.items) |export_entry| {
        // a. Assert: module provides the direct binding for this export.
        // b. Assert: exportEntry.[[ExportName]] is not null.
        // c. Append exportEntry.[[ExportName]] to exportedNames.
        try exported_names.append(agent.gc_allocator, export_entry.export_name.?);
    }

    // 7. For each ExportEntry Record exportEntry of module.[[IndirectExportEntries]], do
    for (self.indirect_export_entries.items) |export_entry| {
        // a. Assert: module imports a specific binding for this export.
        // b. Assert: exportEntry.[[ExportName]] is not null.
        // c. Append exportEntry.[[ExportName]] to exportedNames.
        try exported_names.append(agent.gc_allocator, export_entry.export_name.?);
    }

    // 8. For each ExportEntry Record exportEntry of module.[[StarExportEntries]], do
    for (self.star_export_entries.items) |export_entry| {
        // a. Assert: exportEntry.[[ModuleRequest]] is not null.
        std.debug.assert(export_entry.module_request != null);

        // b. Let requestedModule be GetImportedModule(module, exportEntry.[[ModuleRequest]]).
        const requested_module = getImportedModule(self, export_entry.module_request.?);

        // c. Let starNames be requestedModule.GetExportedNames(exportStarSet).
        const star_names = try requested_module.getExportedNames(agent, export_star_set);

        // d. For each element name of starNames, do
        for (star_names) |name| {
            // i. If name is not "default", then
            if (!std.mem.eql(u8, name, "default")) {
                // 1. If exportedNames does not contain name, then
                if (!containsSlice(exported_names.items, name)) {
                    // a. Append name to exportedNames.
                    try exported_names.append(agent.gc_allocator, name);
                }
            }
        }
    }

    // 9. Return exportedNames.
    return exported_names.toOwnedSlice(agent.gc_allocator);
}

/// 16.2.1.7.2.2 ResolveExport ( exportName [ , resolveSet ] )
/// https://tc39.es/ecma262/#sec-resolveexport
pub fn resolveExport(
    self: *SourceTextModule,
    agent: *Agent,
    export_name: []const u8,
    maybe_resolve_set: ?*Module.ResolveSet,
) std.mem.Allocator.Error!?ResolvedBindingOrAmbiguous {
    // 1. Assert: module.[[Status]] is not new.
    std.debug.assert(self.status != .new);

    // 2. If resolveSet is not present, set resolveSet to a new empty List.
    var new_resolve_set: Module.ResolveSet = undefined;
    defer if (maybe_resolve_set == null) new_resolve_set.deinit(agent.gc_allocator);
    var resolve_set = maybe_resolve_set orelse blk: {
        new_resolve_set = .empty;
        break :blk &new_resolve_set;
    };

    const resolve_set_key: @FieldType(Module.ResolveSet.KV, "key") = .{
        .module = self,
        .export_name = export_name,
    };

    // 3. For each Record { [[Module]], [[ExportName]] } record of resolveSet, do
    //     a. If module and record.[[Module]] are the same Module Record and exportName is
    //        record.[[ExportName]], then
    if (resolve_set.contains(resolve_set_key)) {
        // i. Assert: This is a circular import request.
        // ii. Return null.
        return null;
    }

    // 4. Append the Record { [[Module]]: module, [[ExportName]]: exportName } to resolveSet.
    try resolve_set.putNoClobber(agent.gc_allocator, resolve_set_key, {});

    // 5. For each ExportEntry Record exportEntry of module.[[LocalExportEntries]], do
    for (self.local_export_entries.items) |export_entry| {
        // a. If exportEntry.[[ExportName]] is exportName, then
        if (std.mem.eql(u8, export_entry.export_name.?, export_name)) {
            // i. Assert: module provides the direct binding for this export.
            // ii. Return ResolvedBinding Record { [[Module]]: module,
            //     [[BindingName]]: exportEntry.[[LocalName]] }.
            return .{
                .resolved_binding = .{
                    .module = .{ .source_text_module = self },
                    .binding_name = .{ .string = export_entry.local_name.? },
                },
            };
        }
    }

    // 6. For each ExportEntry Record exportEntry of module.[[IndirectExportEntries]], do
    for (self.indirect_export_entries.items) |export_entry| {
        // a. If exportEntry.[[ExportName]] is exportName, then
        if (std.mem.eql(u8, export_entry.export_name.?, export_name)) {
            // i. Assert: exportEntry.[[ModuleRequest]] is not null.
            std.debug.assert(export_entry.module_request != null);

            // ii. Let importedModule be GetImportedModule(module, exportEntry.[[ModuleRequest]]).
            const imported_module = getImportedModule(self, export_entry.module_request.?);

            // iii. If exportEntry.[[ImportName]] is namespace, then
            if (export_entry.import_name != null and export_entry.import_name.? == .namespace) {
                // 1. Assert: module does not provide the direct binding for this export.
                // 2. Return ResolvedBinding Record { [[Module]]: importedModule,
                //    [[BindingName]]: namespace }.
                return .{
                    .resolved_binding = .{
                        .module = imported_module,
                        .binding_name = .namespace,
                    },
                };
            }

            // iv. Assert: module imports a specific binding for this export.
            // v. Assert: exportEntry.[[ImportName]] is a String.
            // vi. Return importedModule.ResolveExport(exportEntry.[[ImportName]], resolveSet).
            return imported_module.resolveExport(
                agent,
                export_entry.import_name.?.string,
                resolve_set,
            );
        }
    }

    // 7. If exportName is "default", then
    if (std.mem.eql(u8, export_name, "default")) {
        // a. Assert: A `default` export was not explicitly defined by this module.
        // b. Return null.
        // c. NOTE: A `default` export cannot be provided by an `export * from "mod"` declaration.
        return null;
    }

    // 8. Let starResolution be null.
    var maybe_star_resolution: ?ResolvedBinding = null;

    // 9. For each ExportEntry Record exportEntry of module.[[StarExportEntries]], do
    for (self.star_export_entries.items) |export_entry| {
        // a. Assert: exportEntry.[[ModuleRequest]] is not null.
        std.debug.assert(export_entry.module_request != null);

        // b. Let importedModule be GetImportedModule(module, exportEntry.[[ModuleRequest]]).
        const imported_module = getImportedModule(self, export_entry.module_request.?);

        // c. Let resolution be importedModule.ResolveExport(exportName, resolveSet).
        const maybe_resolution = try imported_module.resolveExport(
            agent,
            export_name,
            resolve_set,
        );

        // d. If resolution is ambiguous, return ambiguous.
        if (maybe_resolution != null and maybe_resolution.? == .ambiguous) return .ambiguous;

        // e. If resolution is not null, then
        if (maybe_resolution != null) {
            // i. Assert: resolution is a ResolvedBinding Record.
            const resolution = maybe_resolution.?.resolved_binding;

            // ii. If starResolution is null, then
            const star_resolution = maybe_star_resolution orelse {
                // 1. Set starResolution to resolution.
                maybe_star_resolution = resolution;
                continue;
            };

            // iii. Else,
            // 1. Assert: There is more than one `*` export that includes the requested name.

            // 2. If resolution.[[Module]] and starResolution.[[Module]] are not the same Module
            //    Record, return ambiguous.
            if (!std.meta.eql(resolution.module, star_resolution.module)) {
                return .ambiguous;
            }

            // 3. If resolution.[[BindingName]] is not starResolution.[[BindingName]], return
            //    ambiguous.
            if ((resolution.binding_name == .namespace and star_resolution.binding_name == .string) or
                (resolution.binding_name == .string and star_resolution.binding_name == .namespace) or
                (resolution.binding_name == .string and star_resolution.binding_name == .string and
                    !std.mem.eql(u8, resolution.binding_name.string, star_resolution.binding_name.string)))
            {
                return .ambiguous;
            }
        }
    }

    // 10. Return starResolution.
    return if (maybe_star_resolution) |resolved_binding|
        .{ .resolved_binding = resolved_binding }
    else
        null;
}

/// 16.2.1.7.3.1 InitializeEnvironment ( )
/// https://tc39.es/ecma262/#sec-source-text-module-record-initialize-environment
fn initializeEnvironment(self: *SourceTextModule, agent: *Agent) Agent.Error!void {
    // 1. For each ExportEntry Record exportEntry of module.[[IndirectExportEntries]], do
    for (self.indirect_export_entries.items) |export_entry| {
        // a. Assert: exportEntry.[[ExportName]] is not null.
        // b. Let resolution be module.ResolveExport(exportEntry.[[ExportName]]).
        const maybe_resolution = try self.resolveExport(agent, export_entry.export_name.?, null);

        // c. If resolution is either null or ambiguous, throw a SyntaxError exception.
        if (maybe_resolution) |resolution| switch (resolution) {
            .ambiguous => return agent.throwException(
                .syntax_error,
                "Ambiguous star export '{f}' in module '{f}'",
                .{
                    std.unicode.fmtUtf8(export_entry.export_name.?),
                    export_entry.module_request.?.specifier.fmtEscaped(),
                },
            ),

            // d. Assert: resolution is a ResolvedBinding Record.
            .resolved_binding => {},
        } else {
            return agent.throwException(
                .syntax_error,
                "No export named '{f}' in module '{f}'",
                .{
                    std.unicode.fmtUtf8(export_entry.export_name.?),
                    export_entry.module_request.?.specifier.fmtEscaped(),
                },
            );
        }
    }

    // 2. Assert: All named exports from module are resolvable.

    // 3. Let realm be module.[[Realm]].
    // 4. Assert: realm is not undefined.
    const realm = self.realm;

    // 5. Let envRecord be NewModuleEnvironment(realm.[[GlobalEnv]]).
    const env: Environment = .{
        .module_environment = try newModuleEnvironment(agent.gc_allocator, realm.global_env),
    };

    // 6. Set module.[[Environment]] to envRecord.
    self.environment = env;

    // 7. For each ImportEntry Record importEntry of module.[[ImportEntries]], do
    for (self.import_entries.items) |import_entry| {
        // a. Let importedModule be GetImportedModule(module, importEntry.[[ModuleRequest]]).
        const imported_module = getImportedModule(self, import_entry.module_request);

        const local_name = try String.fromWtf8(agent, import_entry.local_name);

        switch (import_entry.import_name.?) {
            // b. If importEntry.[[ImportName]] is namespace, then
            .namespace => {
                // i. Let namespace be GetModuleNamespace(importedModule).
                const namespace = try getModuleNamespace(agent, imported_module);

                // ii. Perform ! envRecord.CreateImmutableBinding(importEntry.[[LocalName]], true).
                env.createImmutableBinding(
                    agent,
                    local_name,
                    true,
                ) catch |err| try noexcept(err);

                // iii. Perform ! envRecord.InitializeBinding(importEntry.[[LocalName]], namespace).
                env.initializeBinding(
                    agent,
                    local_name,
                    Value.from(&namespace.object),
                ) catch |err| try noexcept(err);
            },
            // c. Else,
            // i. Assert: importEntry.[[ImportName]] is a String.
            .string => |import_name| {
                // ii. Let resolution be importedModule.ResolveExport(importEntry.[[ImportName]]).
                const maybe_resolution = try imported_module.resolveExport(
                    agent,
                    import_name,
                    null,
                );

                // iii. If resolution is either null or ambiguous, throw a SyntaxError exception.
                const resolution = if (maybe_resolution) |resolution| switch (resolution) {
                    .ambiguous => return agent.throwException(
                        .syntax_error,
                        "Ambiguous star export '{f}' in module '{f}'",
                        .{
                            std.unicode.fmtUtf8(import_name),
                            import_entry.module_request.specifier.fmtEscaped(),
                        },
                    ),
                    .resolved_binding => |resolved_binding| resolved_binding,
                } else {
                    return agent.throwException(
                        .syntax_error,
                        "No export named '{f}' in module '{f}'",
                        .{
                            std.unicode.fmtUtf8(import_name),
                            import_entry.module_request.specifier.fmtEscaped(),
                        },
                    );
                };

                // iv. If resolution.[[BindingName]] is namespace, then
                switch (resolution.binding_name) {
                    .namespace => {
                        // 1. Let namespace be GetModuleNamespace(resolution.[[Module]]).
                        const namespace = try getModuleNamespace(agent, resolution.module);

                        // 2. Perform ! envRecord.CreateImmutableBinding(importEntry.[[LocalName]],
                        //    true).
                        env.createImmutableBinding(
                            agent,
                            local_name,
                            true,
                        ) catch |err| try noexcept(err);

                        // 3. Perform ! envRecord.InitializeBinding(importEntry.[[LocalName]],
                        //    namespace).
                        env.initializeBinding(
                            agent,
                            local_name,
                            Value.from(&namespace.object),
                        ) catch |err| try noexcept(err);
                    },
                    .string => |binding_name| {
                        // v. Else,
                        // 1. Perform CreateImportBinding(envRecord, importEntry.[[LocalName]],
                        //    resolution.[[Module]], resolution.[[BindingName]]).
                        try env.module_environment.createImportBinding(
                            agent,
                            local_name,
                            resolution.module,
                            try String.fromWtf8(agent, binding_name),
                        );
                    },
                }
            },
        }
    }

    // 8. Let moduleContext be a new ECMAScript code execution context.
    const module_context = try agent.gc_allocator.create(ExecutionContext);
    module_context.* = .{
        // 9. Set the Function of moduleContext to null.
        .origin = .module,

        // 10. Assert: module.[[Realm]] is not undefined.
        // 11. Set the Realm of moduleContext to module.[[Realm]].
        .realm = self.realm,

        // 12. Set the ScriptOrModule of moduleContext to module.
        .script_or_module = .{ .module = .{ .source_text_module = self } },

        .ecmascript_code = .{
            // 13. Set the VariableEnvironment of moduleContext to module.[[Environment]].
            .variable_environment = self.environment.?,

            // 14. Set the LexicalEnvironment of moduleContext to module.[[Environment]].
            .lexical_environment = self.environment.?,

            // 15. Set the PrivateEnvironment of moduleContext to null.
            .private_environment = null,
        },
    };

    // 16. Set module.[[Context]] to moduleContext.
    self.context = module_context;

    // 17. Push moduleContext onto the execution context stack; moduleContext is now the running
    //     execution context.
    try agent.execution_context_stack.append(agent.gc_allocator, module_context);

    // 18. Let code be module.[[ECMAScriptCode]].
    const code = self.ecmascript_code;

    // 19. Let variableDecls be the VarScopedDeclarations of code.
    var variable_decls: std.ArrayList(ast.VarScopedDeclaration) = .empty;
    defer variable_decls.deinit(agent.gc_allocator);
    try code.collectVarScopedDeclarations(agent.gc_allocator, &variable_decls);

    // 20. Let declaredVariableNames be a new empty List.
    var declared_variable_names: String.HashMap(void) = .empty;
    defer declared_variable_names.deinit(agent.gc_allocator);

    var bound_names: std.ArrayList(ast.Identifier) = .empty;
    defer bound_names.deinit(agent.gc_allocator);

    // 21. For each element variableDecl of variableDecls, do
    for (variable_decls.items) |variable_scoped_decl| {
        bound_names.clearRetainingCapacity();
        switch (variable_scoped_decl) {
            .variable_declaration => |variable_decl| try variable_decl.collectBoundNames(agent.gc_allocator, &bound_names),
            .hoistable_declaration => |hoistable_decl| switch (hoistable_decl) {
                inline else => |func_decl| try bound_names.append(agent.gc_allocator, func_decl.identifier.?),
            },
        }

        // a. For each element name of the BoundNames of variableDecl, do
        for (bound_names.items) |name_utf8| {
            const name = try String.fromUtf8(agent, name_utf8);

            // i. If declaredVariableNames does not contain name, then
            if (!declared_variable_names.contains(name)) {
                // 1. Perform ! envRecord.CreateMutableBinding(name, false).
                env.createMutableBinding(agent, name, false) catch |err| try noexcept(err);

                // 2. Perform ! envRecord.InitializeBinding(name, undefined).
                env.initializeBinding(agent, name, .undefined) catch |err| try noexcept(err);

                // 3. Append name to declaredVariableNames.
                try declared_variable_names.putNoClobber(agent.gc_allocator, name, {});
            }
        }
    }

    // 22. Let lexicalDecls be the LexicallyScopedDeclarations of code.
    var lexical_decls: std.ArrayList(ast.LexicallyScopedDeclaration) = .empty;
    defer lexical_decls.deinit(agent.gc_allocator);
    try code.collectLexicallyScopedDeclarations(agent.gc_allocator, &lexical_decls);

    // 23. Let privateEnv be null.
    const private_env = null;

    // 24. For each element lexicalDecl of lexicalDecls, do
    for (lexical_decls.items) |lexical_decl| {
        bound_names.clearRetainingCapacity();
        try lexical_decl.collectBoundNames(agent.gc_allocator, &bound_names);

        // a. For each element name of the BoundNames of lexicalDecl, do
        for (bound_names.items) |name_utf8| {
            const name = try String.fromUtf8(agent, name_utf8);

            // i. If IsConstantDeclaration of lexicalDecl is true, then
            if (lexical_decl.isConstantDeclaration()) {
                // 1. Perform ! envRecord.CreateImmutableBinding(name, true).
                env.createImmutableBinding(agent, name, true) catch |err| try noexcept(err);
            } else {
                // ii. Else,
                // 1. Perform ! envRecord.CreateMutableBinding(name, false).
                env.createMutableBinding(agent, name, false) catch |err| try noexcept(err);
            }

            // iii. If lexicalDecl is either a FunctionDeclaration, a GeneratorDeclaration, an
            //      AsyncFunctionDeclaration, or an AsyncGeneratorDeclaration, then
            if (lexical_decl == .hoistable_declaration) {
                const hoistable_decl = lexical_decl.hoistable_declaration;

                // 1. Let funcObj be InstantiateFunctionObject of lexicalDecl with arguments
                //    envRecord and privateEnv.
                const func_obj = try switch (hoistable_decl) {
                    .function_declaration => |func_decl| instantiateOrdinaryFunctionObject(agent, func_decl, env, private_env, self.source),
                    .generator_declaration => |gen_decl| instantiateGeneratorFunctionObject(agent, gen_decl, env, private_env, self.source),
                    .async_function_declaration => |async_func_decl| instantiateAsyncFunctionObject(agent, async_func_decl, env, private_env, self.source),
                    .async_generator_declaration => |async_gen_decl| instantiateAsyncGeneratorFunctionObject(agent, async_gen_decl, env, private_env, self.source),
                };

                // 2. Perform ! envRecord.InitializeBinding(name, funcObj).
                env.initializeBinding(
                    agent,
                    name,
                    Value.from(&func_obj.object),
                ) catch |err| try noexcept(err);
            }
        }
    }

    // 25. Remove moduleContext from the execution context stack.
    _ = agent.execution_context_stack.pop().?;

    // 26. Return unused.
}

/// 16.2.1.7.3.2 ExecuteModule ( [ capability ] )
/// https://tc39.es/ecma262/#sec-source-text-module-record-execute-module
fn executeModule(
    self: *SourceTextModule,
    agent: *Agent,
    capability: ?PromiseCapability,
) Agent.Error!void {
    // 1. Assert: module has been linked and declarations in its module environment have been
    //    instantiated.
    std.debug.assert(self.environment != null and self.context != null);

    // 2. Let moduleContext be module.[[Context]].
    const module_context = self.context.?;

    // 3. If module.[[HasTLA]] is false, then
    if (!self.has_tla) {
        // a. Assert: capability is not present.
        std.debug.assert(capability == null);

        // b. Let env be module.[[Environment]].
        // c. Suspend the running execution context.

        // d. Push moduleContext onto the execution context stack; moduleContext is now the running
        //    execution context.
        try agent.execution_context_stack.append(agent.gc_allocator, module_context);

        // e. Let result be Completion(Evaluation of module.[[ECMAScriptCode]]).
        // f. Set result to Completion(DisposeResources(env.[[DisposableResourceStack]], result)).
        const result = interpreter.compileAndRun(agent, .{ .module = &self.ecmascript_code }, "<module>");

        // g. Suspend moduleContext and remove it from the execution context stack.
        _ = agent.execution_context_stack.pop().?;

        // h. Resume the context that is now on the top of the execution context stack as the
        //    running execution context.

        // i. If result is an abrupt completion, then
        //     i. Return ? result.
        _ = try result;
    } else {
        // 4. Else,
        // a. Assert: capability is a PromiseCapability Record.
        std.debug.assert(capability != null);

        // b. Perform AsyncBlockStart(capability, module.[[ECMAScriptCode]], moduleContext).
        try asyncBlockStart(
            agent,
            capability.?,
            .{ .module = self.ecmascript_code },
            module_context,
        );
    }

    // 5. Return unused.
}
