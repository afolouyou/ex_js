//! 9.3 Realms
//! https://tc39.es/ecma262/#sec-code-realms

const std = @import("std");

const builtins = @import("../builtins.zig");
const environments = @import("environments.zig");
const language = @import("../language.zig");
const types = @import("../types.zig");

const Agent = @import("Agent.zig");
const ExecutionContext = @import("ExecutionContext.zig");
const GlobalEnvironment = environments.GlobalEnvironment;
const Module = language.Module;
const ModuleRequest = language.ModuleRequest;
const Object = types.Object;
const PropertyKey = types.PropertyKey;
const String = types.String;
const addRestrictedFunctionProperties = builtins.addRestrictedFunctionProperties;
const globalObjectProperties = builtins.globalObjectProperties;
const newGlobalEnvironment = environments.newGlobalEnvironment;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;

pub const Intrinsics = @import("Realm/Intrinsics.zig");
pub const Shapes = @import("Realm/Shapes.zig");

const Realm = @This();

/// [[AgentSignifier]]
agent: *Agent,

/// [[Intrinsics]]
intrinsics: Intrinsics,

/// [[GlobalObject]]
global_object: *Object,

/// [[GlobalEnv]]
global_env: *GlobalEnvironment,

/// [[TemplateMap]]
template_map: std.AutoHashMapUnmanaged(u64, *builtins.Array),

/// [[LoadedModules]]
loaded_modules: ModuleRequest.HashMap(Module),

/// [[HostDefined]]
host_defined: ?*anyopaque,

/// Non-standard, needed for `Math.random()`
rng: std.Random.DefaultPrng,

shapes: Shapes,

pub const Intrinsic = std.meta.FieldEnum(Intrinsics);

pub fn intrinsic(realm: *Realm, comptime field: Intrinsic) std.mem.Allocator.Error!Intrinsics.Result(field) {
    return realm.intrinsics.getOrCreate(realm, field);
}

pub const Shape = std.meta.FieldEnum(Shapes);

pub fn shape(realm: *Realm, comptime field: Shape) std.mem.Allocator.Error!Shapes.Result(field) {
    return realm.shapes.getOrCreate(realm, field);
}

/// 9.3.1 InitializeHostDefinedRealm ( )
/// https://tc39.es/ecma262/#sec-initializehostdefinedrealm
pub fn initializeHostDefinedRealm(
    agent: *Agent,
    args: struct {
        global_object: ?*Object = null,
        this_value: ?*Object = null,
    },
) Agent.Error!void {
    // 1. Let realm be a new Realm Record.
    var realm = try agent.gc_allocator.create(Realm);

    // Set this early, it'll be accessed before the realm struct is fully initialized.
    realm.agent = agent;

    // 2. Perform CreateIntrinsics(realm).
    try realm.createIntrinsics(agent);

    realm.* = .{
        .intrinsics = realm.intrinsics,
        .shapes = .init,
        .rng = .init(@intFromPtr(realm)),
        .global_object = undefined,
        .global_env = undefined,

        // 3. Set realm.[[AgentSignifier]] to AgentSignifier().
        .agent = realm.agent,

        // 4. Set realm.[[TemplateMap]] to a new empty List.
        .template_map = .empty,

        .loaded_modules = .empty,
        .host_defined = null,
    };

    // 5. Let newContext be a new execution context.
    const new_context = try agent.gc_allocator.create(ExecutionContext);
    new_context.* = .{
        // 6. Set the Function of newContext to null.
        .origin = .realm,

        // 7. Set the Realm of newContext to realm.
        .realm = realm,

        // 8. Set the ScriptOrModule of newContext to null.
        .script_or_module = null,

        .ecmascript_code = undefined,
    };

    // 9. Push newContext onto the execution context stack; newContext is now the running execution
    //    context.
    try agent.execution_context_stack.append(agent.gc_allocator, new_context);

    // 10. If the host requires use of a specific object to serve as realm's global object, then
    //     a. Let global be such an object created in a host-defined manner.
    // 11. Else,
    //     a. Let global be OrdinaryObjectCreate(realm.[[Intrinsics]].[[%Object.prototype%]]).
    const global = args.global_object orelse try ordinaryObjectCreate(
        agent,
        try realm.intrinsic(.object_prototype),
    );
    global.shape = try global.shape.makeUnique(agent.gc_allocator);

    // 12. If the host requires that the `this` binding in realm's global scope return an object
    //     other than the global object, then
    //     a. Let thisValue be such an object created in a host-defined manner.
    // 13. Else,
    //     a. Let thisValue be global.
    const this_value = args.this_value orelse global;

    // 14. Set realm.[[GlobalObject]] to global.
    realm.global_object = global;

    // 15. Set realm.[[GlobalEnv]] to NewGlobalEnvironment(global, thisValue).
    realm.global_env = try newGlobalEnvironment(agent.gc_allocator, global, this_value);

    // 16. Perform ? SetDefaultGlobalBindings(realm).
    try realm.setDefaultGlobalBindings();

    // 17. Create any host-defined global object properties on global.
    // 18. Return unused.
}

/// 9.3.2 CreateIntrinsics ( realmRecord )
/// https://tc39.es/ecma262/#sec-createintrinsics
fn createIntrinsics(realm: *Realm, agent: *Agent) std.mem.Allocator.Error!void {
    // 1. Set realmRecord.[[Intrinsics]] to a new Record.
    realm.intrinsics = .init;

    // Ensure %Object.prototype% exists before %Function.prototype% is created, otherwise the
    // latter will be created twice.
    _ = try realm.intrinsic(.object_prototype);

    // 2. Set fields of realmRecord.[[Intrinsics]] with the values listed in Table 6. The field
    //    names are the names listed in the “Intrinsic Name” column of the table. The value of each
    //    field is a new object value fully and recursively populated with property values as
    //    defined by the specification of each object in clauses 19 through 28. All object property
    //    values are newly created object values. All values that are built-in function objects are
    //    created by performing CreateBuiltinFunction(steps, length, name, slots, realmRecord,
    //    proto, async) where steps is the definition of that function provided by this
    //    specification, name is the initial value of the function's "name" property, length is the
    //    initial value of the function's "length" property, slots is a list of the names, if any,
    //    of the function's specified internal slots, proto is the specified value of the function's
    //    [[Prototype]] internal slot, and async is true if the function is described as “async” and
    //    false otherwise. The creation of the intrinsics and their properties must be ordered to
    //    avoid any dependencies upon objects that have not yet been created.
    // NOTE: Intrinsics are lazily allocated, see the struct itself for details.

    // 3. Perform AddRestrictedFunctionProperties(
    //    realmRecord.[[Intrinsics]].[[%Function.prototype%]], realmRecord).
    try addRestrictedFunctionProperties(
        agent,
        try realm.intrinsic(.function_prototype),
        realm,
    );

    // 4. Return unused.
}

/// 9.3.3 SetDefaultGlobalBindings ( realmRecord )
/// https://tc39.es/ecma262/#sec-setdefaultglobalbindings
fn setDefaultGlobalBindings(realm: *Realm) Agent.Error!void {
    const agent = realm.agent;

    // 1. Let global be realmRecord.[[GlobalObject]].
    const global = realm.global_object;

    // Why export a constant when you can do reflection instead!
    const global_properties_count = @typeInfo(@typeInfo(@TypeOf(globalObjectProperties)).@"fn".return_type.?).array.len;
    const lazy_properties_count = global_properties_count - 4; // globalThis, Infinity, NaN, undefined
    try global.ensureProperties(agent.gc_allocator, global_properties_count);
    const extra_data = try global.ensureExtraData(agent.gc_allocator);
    try extra_data.lazy_properties.ensureUnusedCapacity(agent.gc_allocator, lazy_properties_count);

    // 2. For each property of the Global Object specified in clause 19, do
    for (globalObjectProperties(realm)) |property| {
        // a. Let name be the String value of the property name.
        const name = try String.fromAscii(agent, property[0]);
        const property_key = PropertyKey.from(name);

        // b. Let propertyDesc be the fully populated data Property Descriptor for the property,
        //    containing the specified attributes for the property. For properties listed in 19.2,
        //    19.3, or 19.4 the value of the [[Value]] attribute is the corresponding intrinsic
        //    object from realmRecord.
        switch (property[1]) {
            .property_descriptor => |property_desc| {
                // c. Perform ? DefinePropertyOrThrow(global, name, propertyDesc).
                try global.definePropertyOrThrow(agent, property_key, property_desc);
            },
            .lazy_property => |initializer| {
                // NOTE: There aren't any accessors on the global object so this only ever creates data properties.
                std.debug.assert(initializer == .value);
                try global.definePropertyOrThrow(agent, property_key, .{
                    .value = .uninitialized,
                    .writable = true,
                    .enumerable = false,
                    .configurable = true,
                });
                extra_data.lazy_properties.putAssumeCapacity(property_key, .{
                    .realm = realm,
                    .initializer = initializer,
                });
            },
        }
    }

    // 3. Return unused.
}
