pub const BigInt = @import("language/BigInt.zig");
pub const MakeObject = @import("language/Object/make_object.zig").MakeObject;
pub const Number = @import("language/number.zig").Number;
pub const Object = @import("language/Object.zig");
pub const String = @import("language/String.zig");
pub const Symbol = @import("language/Symbol.zig");
pub const Value = @import("language/Value.zig");
pub const createArrayFromList = Value.createArrayFromList;
pub const createArrayFromListMapToValue = Value.createArrayFromListMapToValue;
pub const isLessThan = Value.isLessThan;
pub const isLooselyEqual = Value.isLooselyEqual;
pub const isStrictlyEqual = Value.isStrictlyEqual;
pub const sameType = Value.sameType;
pub const sameValue = Value.sameValue;
pub const sameValueZero = Value.sameValueZero;

test {
    _ = BigInt;
    _ = Number;
    _ = Object;
    _ = String;
    _ = Symbol;
    _ = Value;
}
