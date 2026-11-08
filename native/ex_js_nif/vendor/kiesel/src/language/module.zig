const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const language = @import("../language.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const PromiseCapability = builtins.promise.PromiseCapability;
const Realm = execution.Realm;
const Script = language.Script;
const SourceTextModule = language.SourceTextModule;
const SyntheticModule = language.SyntheticModule;
const String = types.String;
const Value = types.Value;
const continueModuleLoading = language.continueModuleLoading;
const createBuiltinFunction = builtins.createBuiltinFunction;
const moduleNamespaceCreate = builtins.moduleNamespaceCreate;
const noexcept = utils.noexcept;
const performPromiseThen = builtins.performPromiseThen;

/// https://tc39.es/ecma262/#modulerequest-record
pub const ModuleRequest = struct {
    specifier: *const String,
    attributes: []const ImportAttribute,

    /// 16.2.1.3.1 ModuleRequestsEqual ( x, y )
    /// https://tc39.es/ecma262/#sec-ModuleRequestsEqual
    pub fn eql(x: ModuleRequest, y: ModuleRequest) bool {
        // 1. If x.[[Specifier]] is not y.[[Specifier]], return false.
        if (!x.specifier.eql(y.specifier)) return false;

        // 2. Let xAttrs be x.[[Attributes]].
        const x_attrs = x.attributes;

        // 3. Let yAttrs be y.[[Attributes]].
        const y_attrs = y.attributes;

        // 4. Let xAttrsCount be the number of elements in xAttrs.
        // 5. Let yAttrsCount be the number of elements in yAttrs.
        // 6. If xAttrsCount ≠ yAttrsCount, return false.
        if (x_attrs.len != y_attrs.len) return false;

        // 7. For each ImportAttribute Record xAttr of xAttrs, do
        for (x_attrs) |x_attr| {
            // a. If yAttrs does not contain an ImportAttribute Record yAttr such that xAttr.[[Key]]
            //    is yAttr.[[Key]] and xAttr.[[Value]] is yAttr.[[Value]], return false.
            for (y_attrs) |y_attr| {
                if (x_attr.key.eql(y_attr.key) and x_attr.value.eql(y_attr.value)) break;
            } else return false;
        }

        // 8. Return true.
        return true;
    }

    pub fn HashMap(comptime V: type) type {
        return std.HashMapUnmanaged(ModuleRequest, V, struct {
            pub fn hash(_: @This(), key: ModuleRequest) u64 {
                // The order of import attributes doesn't matter so we force a hash collision for
                // equal specifiers and defer to eql() for the final decision.
                return key.specifier.hash;
            }

            pub fn eql(_: @This(), a: ModuleRequest, b: ModuleRequest) bool {
                return a.eql(b);
            }
        }, std.hash_map.default_max_load_percentage);
    }

    pub fn ArrayHashMap(comptime V: type) type {
        return std.array_hash_map.Custom(ModuleRequest, V, struct {
            pub fn hash(_: @This(), key: ModuleRequest) u32 {
                // The order of import attributes doesn't matter so we force a hash collision for
                // equal specifiers and defer to eql() for the final decision.
                return @truncate(key.specifier.hash);
            }

            pub fn eql(_: @This(), a: ModuleRequest, b: ModuleRequest, _: usize) bool {
                return a.eql(b);
            }
        }, false);
    }
};

/// https://tc39.es/ecma262/#importattribute-record
pub const ImportAttribute = struct {
    key: *const String,
    value: *const String,
};

/// 16.2.1.5 Abstract Module Records
/// https://tc39.es/ecma262/#sec-abstract-module-records
pub const Module = union(enum) {
    source_text_module: *SourceTextModule,
    synthetic_module: *SyntheticModule,

    const ExportStarSetKey = *const anyopaque;
    pub const ExportStarSet = std.AutoHashMapUnmanaged(ExportStarSetKey, void);

    const ResolveSetKey = struct {
        module: *const anyopaque,
        export_name: []const u8,
    };
    pub const ResolveSet = std.HashMapUnmanaged(ResolveSetKey, void, struct {
        pub fn hash(_: anytype, key: ResolveSetKey) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(std.mem.asBytes(&key.module));
            hasher.update(key.export_name);
            return hasher.final();
        }

        pub fn eql(_: anytype, a: ResolveSetKey, b: ResolveSetKey) bool {
            return a.module == b.module and std.mem.eql(u8, a.export_name, b.export_name);
        }
    }, std.hash_map.default_max_load_percentage);

    pub fn loadRequestedModules(
        self: Module,
        agent: *Agent,
        host_defined: ?*anyopaque,
    ) std.mem.Allocator.Error!*builtins.Promise {
        return switch (self) {
            .source_text_module => |module| module.loadRequestedModules(agent, host_defined),
            .synthetic_module => |module| module.loadRequestedModules(agent, host_defined),
        };
    }

    pub fn getExportedNames(
        self: Module,
        agent: *Agent,
        maybe_export_star_set: ?*ExportStarSet,
    ) std.mem.Allocator.Error![]const []const u8 {
        return switch (self) {
            .source_text_module => |module| module.getExportedNames(agent, maybe_export_star_set),
            .synthetic_module => |module| module.getExportedNames(agent, maybe_export_star_set),
        };
    }

    pub fn resolveExport(
        self: Module,
        agent: *Agent,
        export_name: []const u8,
        maybe_resolve_set: ?*ResolveSet,
    ) std.mem.Allocator.Error!?ResolvedBindingOrAmbiguous {
        return switch (self) {
            .source_text_module => |module| module.resolveExport(agent, export_name, maybe_resolve_set),
            .synthetic_module => |module| module.resolveExport(agent, export_name, maybe_resolve_set),
        };
    }

    pub fn link(self: Module, agent: *Agent) Agent.Error!void {
        return switch (self) {
            .source_text_module => |module| module.link(agent),
            .synthetic_module => |module| module.link(agent),
        };
    }

    pub fn evaluate(self: Module, agent: *Agent) std.mem.Allocator.Error!*builtins.Promise {
        return switch (self) {
            .source_text_module => |module| module.evaluate(agent),
            .synthetic_module => |module| module.evaluate(agent),
        };
    }

    /// 16.2.1.5.1 EvaluateModuleSync ( module )
    /// https://tc39.es/ecma262/#sec-EvaluateModuleSync
    pub fn evaluateSync(self: Module, agent: *Agent) Agent.Error!void {
        // 1. Assert: module is not a Cyclic Module Record.
        std.debug.assert(self != .source_text_module);

        // 2. Let promise be module.Evaluate().
        const promise = try self.evaluate(agent);

        // 3. Assert: promise.[[PromiseState]] is either fulfilled or rejected.
        std.debug.assert(promise.fields.promise_state == .fulfilled or
            promise.fields.promise_state == .rejected);

        // 4. If promise.[[PromiseState]] is rejected, then
        if (promise.fields.promise_state == .rejected) {
            // a. If promise.[[PromiseIsHandled]] is false, perform HostPromiseRejectionTracker(
            //    promise, "handle").
            if (promise.fields.promise_is_handled == false) {
                agent.host_hooks.hostPromiseRejectionTracker(agent, promise, .handle);
            }

            // b. Set promise.[[PromiseIsHandled]] to true.
            promise.fields.promise_is_handled = true;

            // c. Throw promise.[[PromiseResult]].
            agent.exception = .{
                .value = promise.fields.promise_result,
                // TODO: Capture stack when rejecting a promise
                .stack_trace = &.{},
            };
            return error.ExceptionThrown;
        }

        // 5. Return unused.
    }
};

/// https://tc39.es/ecma262/#graphloadingstate-record
pub const GraphLoadingState = struct {
    pub const Visited = std.AutoHashMapUnmanaged(*SourceTextModule, void);

    /// [[PromiseCapability]]
    promise_capability: PromiseCapability,

    /// [[IsLoading]]
    is_loading: bool,

    /// [[PendingModulesCount]]
    pending_modules_count: usize,

    /// [[Visited]]
    visited: Visited,

    /// [[HostDefined]]
    host_defined: ?*anyopaque,
};

pub const ImportedModuleReferrer = union(enum) {
    script: *Script,
    module: *SourceTextModule,
    realm: *Realm,
};

pub const ImportedModulePayload = union(enum) {
    graph_loading_state: *GraphLoadingState,
    promise_capability: PromiseCapability,
};

/// https://tc39.es/ecma262/#resolvedbinding-record
pub const ResolvedBinding = struct {
    /// [[Module]]
    module: Module,

    /// [[BindingName]]
    binding_name: union(enum) {
        string: []const u8,
        namespace,
    },
};

pub const ResolvedBindingOrAmbiguous = union(enum) {
    resolved_binding: ResolvedBinding,
    ambiguous,
};

/// 13.3.10.3 ContinueDynamicImport ( promiseCapability, moduleCompletion )
/// https://tc39.es/ecma262/#sec-ContinueDynamicImport
fn continueDynamicImport(
    agent: *Agent,
    promise_capability: PromiseCapability,
    module_completion: Agent.Error!Module,
) std.mem.Allocator.Error!void {
    // 1. If moduleCompletion is an abrupt completion, then
    // 2. Let module be moduleCompletion.[[Value]].
    const module = module_completion catch |err| switch (err) {
        error.OutOfMemory => |e| return e,

        error.ExceptionThrown => {
            const exception = agent.clearException();

            // a. Perform ! Call(promiseCapability.[[Reject]], undefined,
            //    « moduleCompletion.[[Value]] »).
            _ = promise_capability.reject.call(
                agent,
                .undefined,
                &.{exception.value},
            ) catch |err_| try noexcept(err_);

            // b. Return unused.
            return;
        },
    };

    // 3. Let loadPromise be module.LoadRequestedModules().
    const load_promise = try module.loadRequestedModules(agent, null);

    const RejectedClosureCaptures = struct {
        promise_capability: PromiseCapability,
    };
    const rejected_closure_captures = try agent.gc_allocator.create(RejectedClosureCaptures);
    rejected_closure_captures.* = .{ .promise_capability = promise_capability };

    // 4. Let rejectedClosure be a new Abstract Closure with parameters (reason) that captures
    //    promiseCapability and performs the following steps when called:
    const rejected_closure = struct {
        fn func(agent_: *Agent, _: Value, arguments_: Arguments) Agent.Error!Value {
            const function = agent_.activeFunctionObject();
            const captures_ = function.as(builtins.BuiltinFunction).fields.additionalFieldsAs(RejectedClosureCaptures);
            const promise_capability_ = captures_.promise_capability;
            const reason = arguments_.get(0);

            // a. Perform ! Call(promiseCapability.[[Reject]], undefined, « reason »).
            _ = promise_capability_.reject.call(
                agent_,
                .undefined,
                &.{reason},
            ) catch |err| try noexcept(err);

            // b. Return NormalCompletion(undefined).
            return .undefined;
        }
    }.func;

    // 5. Let onRejected be CreateBuiltinFunction(rejectedClosure, 1, "", « »).
    const on_rejected = try createBuiltinFunction(
        agent,
        .{ .function = rejected_closure },
        1,
        "",
        .{ .additional_fields = rejected_closure_captures },
    );

    const LinkAndEvaluateClosureCaptures = struct {
        module: Module,
        promise_capability: PromiseCapability,
        on_rejected: *builtins.BuiltinFunction,
    };
    const link_and_evaluate_closure_captures = try agent.gc_allocator.create(LinkAndEvaluateClosureCaptures);
    link_and_evaluate_closure_captures.* = .{
        .module = module,
        .promise_capability = promise_capability,
        .on_rejected = on_rejected,
    };

    // 6. Let linkAndEvaluateClosure be a new Abstract Closure with no parameters that captures
    //    module, promiseCapability, and onRejected and performs the following steps when called:
    const link_and_evaluate_closure = struct {
        fn func(agent_: *Agent, _: Value, _: Arguments) Agent.Error!Value {
            const function = agent_.activeFunctionObject();
            const captures_ = function.as(builtins.BuiltinFunction).fields.additionalFieldsAs(LinkAndEvaluateClosureCaptures);
            const promise_capability_ = captures_.promise_capability;
            const module_ = captures_.module;
            const on_rejected_ = captures_.on_rejected;

            // a. Let link be Completion(module.Link()).
            const link = module_.link(agent_);

            // b. If link is an abrupt completion, then
            link catch |err| switch (err) {
                error.OutOfMemory => |e| return e,

                error.ExceptionThrown => {
                    const exception = agent_.clearException();

                    // i. Perform ! Call(promiseCapability.[[Reject]], undefined,
                    //    « link.[[Value]] »).
                    _ = promise_capability_.reject.call(
                        agent_,
                        .undefined,
                        &.{exception.value},
                    ) catch |err_| try noexcept(err_);

                    // ii. Return NormalCompletion(undefined).
                    return .undefined;
                },
            };

            // c. Let evaluatePromise be module.Evaluate().
            const evaluate_promise = try module_.evaluate(agent_);

            const FulfilledClosureCaptures = struct {
                module: Module,
                promise_capability: PromiseCapability,
            };
            const fulfilled_closure_captures = try agent_.gc_allocator.create(FulfilledClosureCaptures);
            fulfilled_closure_captures.* = .{
                .module = module_,
                .promise_capability = promise_capability_,
            };

            // d. Let fulfilledClosure be a new Abstract Closure with no parameters that captures
            //    module and promiseCapability and performs the following steps when called:
            const fulfilled_closure = struct {
                fn func(agent__: *Agent, _: Value, _: Arguments) Agent.Error!Value {
                    const function_ = agent__.activeFunctionObject();
                    const captures__ = function_.as(builtins.BuiltinFunction).fields.additionalFieldsAs(FulfilledClosureCaptures);
                    const promise_capability__ = captures__.promise_capability;
                    const module__ = captures__.module;

                    // i. Let namespace be GetModuleNamespace(module).
                    const namespace = try getModuleNamespace(agent__, module__);

                    // ii. Perform ! Call(promiseCapability.[[Resolve]], undefined, « namespace »).
                    _ = promise_capability__.resolve.call(
                        agent__,
                        .undefined,
                        &.{Value.from(&namespace.object)},
                    ) catch |err| try noexcept(err);

                    // iii. Return NormalCompletion(undefined).
                    return .undefined;
                }
            }.func;

            // e. Let onFulfilled be CreateBuiltinFunction(fulfilledClosure, 0, "", « »).
            const on_fulfilled = try createBuiltinFunction(
                agent_,
                .{ .function = fulfilled_closure },
                0,
                "",
                .{ .additional_fields = fulfilled_closure_captures },
            );

            // f. Perform PerformPromiseThen(evaluatePromise, onFulfilled, onRejected).
            _ = try performPromiseThen(
                agent_,
                evaluate_promise,
                Value.from(&on_fulfilled.object),
                Value.from(&on_rejected_.object),
                null,
            );

            // g. Return unused.
            return .undefined;
        }
    }.func;

    // 7. Let linkAndEvaluate be CreateBuiltinFunction(linkAndEvaluateClosure, 0, "", « »).
    const link_and_evaluate = try createBuiltinFunction(
        agent,
        .{ .function = link_and_evaluate_closure },
        0,
        "",
        .{ .additional_fields = link_and_evaluate_closure_captures },
    );

    // 8. Perform PerformPromiseThen(loadPromise, linkAndEvaluate, onRejected).
    _ = try performPromiseThen(
        agent,
        load_promise,
        Value.from(&link_and_evaluate.object),
        Value.from(&on_rejected.object),
        null,
    );

    // 9. Return unused.
}

/// 16.2.1.9 GetImportedModule ( referrer, request )
/// https://tc39.es/ecma262/#sec-GetImportedModule
pub fn getImportedModule(referrer: *const SourceTextModule, request: ModuleRequest) Module {
    // 1. Let records be a List consisting of each LoadedModuleRequest Record r of
    //    referrer.[[LoadedModules]] such that ModuleRequestsEqual(r, request) is true.
    // 2. Assert: records has exactly one element, since LoadRequestedModules has completed
    //    successfully on referrer prior to invoking this abstract operation.
    // 3. Let record be the sole element of records.
    // 4. Return record.[[Module]].
    return referrer.loaded_modules.get(request).?;
}

/// 16.2.1.11 FinishLoadingImportedModule ( referrer, moduleRequest, payload, result )
/// https://tc39.es/ecma262/#sec-FinishLoadingImportedModule
pub fn finishLoadingImportedModule(
    agent: *Agent,
    referrer: ImportedModuleReferrer,
    module_request: ModuleRequest,
    payload: ImportedModulePayload,
    result: Agent.Error!Module,
) std.mem.Allocator.Error!void {
    // 1. If result is a normal completion, then
    if (!std.meta.isError(result)) {
        switch (referrer) {
            inline else => |r| {
                const module = result catch unreachable;
                const get_or_put_result = try r.loaded_modules.getOrPut(agent.gc_allocator, module_request);

                // a. If referrer.[[LoadedModules]] contains a LoadedModuleRequest Record record
                //    such that ModuleRequestsEqual(record, moduleRequest) is true, then
                if (get_or_put_result.found_existing) {
                    // i. Assert: record.[[Module]] and result.[[Value]] are the same Module Record.
                    std.debug.assert(std.meta.eql(get_or_put_result.value_ptr.*, module));
                } else {
                    // b. Else,
                    // i. Append the LoadedModuleRequest Record {
                    //    [[Specifier]]: moduleRequest.[[Specifier]],
                    //    [[Attributes]]: moduleRequest.[[Attributes]],
                    //    [[Module]]: result.[[Value]] } to referrer.[[LoadedModules]].
                    get_or_put_result.value_ptr.* = module;
                }
            },
        }
    }

    switch (payload) {
        // 2. If payload is a GraphLoadingState Record, then
        .graph_loading_state => |graph_loading_state| {
            // a. Perform ContinueModuleLoading(payload, result).
            try continueModuleLoading(agent, graph_loading_state, result);
        },
        // 3. Else,
        .promise_capability => |promise_capability| {
            // a. Perform ContinueDynamicImport(payload, result).
            try continueDynamicImport(agent, promise_capability, result);
        },
    }

    // 4. Return unused.
}

/// 16.2.1.12 AllImportAttributesSupported ( attrs )
/// https://tc39.es/ecma262/#sec-AllImportAttributesSupported
pub fn allImportAttributesSupported(
    agent: *Agent,
    attrs: []const ImportAttribute,
) std.mem.Allocator.Error!?*const String {
    // 1. Let supported be HostGetSupportedImportAttributes().
    const supported = try agent.host_hooks.hostGetSupportedImportAttributes(agent);

    // 2. For each ImportAttribute Record attr of attrs, do
    for (attrs) |attr| {
        // a. If supported does not contain attr.[[Key]], return false.
        if (!supported.contains(attr.key)) return attr.key;
    }

    // 3. Return true.
    return null;
}

/// 16.2.1.13 GetModuleNamespace ( module )
/// https://tc39.es/ecma262/#sec-getmodulenamespace
pub fn getModuleNamespace(
    agent: *Agent,
    module: Module,
) std.mem.Allocator.Error!*builtins.ModuleNamespace {
    // 1. Assert: If module is a Cyclic Module Record, then module.[[Status]] is not new or
    //    unlinked.
    if (module == .source_text_module) {
        std.debug.assert(switch (module.source_text_module.status) {
            .new, .unlinked => false,
            else => true,
        });
    }

    // 2. Let namespace be module.[[Namespace]].
    var namespace = switch (module) {
        inline else => |m| m.namespace,
    };

    // 3. If namespace is empty, then
    if (namespace == null) {
        // a. Let exportedNames be module.GetExportedNames().
        const exported_names = try module.getExportedNames(agent, null);
        defer agent.gc_allocator.free(exported_names);

        // b. Let unambiguousNames be a new empty List.
        var unambiguous_names: std.ArrayList([]const u8) = .empty;
        defer unambiguous_names.deinit(agent.gc_allocator);

        // c. For each element name of exportedNames, do
        for (exported_names) |name| {
            // i. Let resolution be module.ResolveExport(name).
            const resolution = try module.resolveExport(agent, name, null);

            // ii. If resolution is a ResolvedBinding Record, append name to unambiguousNames.
            if (resolution != null and resolution.? == .resolved_binding) {
                try unambiguous_names.append(agent.gc_allocator, name);
            }
        }

        // d. Set namespace to ModuleNamespaceCreate(module, unambiguousNames).
        namespace = try moduleNamespaceCreate(agent, module, unambiguous_names.items);
    }

    // 4. Return namespace.
    return namespace.?;
}
