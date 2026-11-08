//! 6.2.10 The PrivateElement Specification Type
//! https://tc39.es/ecma262/#sec-privateelement-specification-type

const types = @import("../../types.zig");

const Object = types.Object;
const Value = types.Value;

pub const PrivateElement = union(enum) {
    field: Value,
    method: *Object,
    accessor: struct {
        getter: ?*Object,
        setter: ?*Object,
    },
};
