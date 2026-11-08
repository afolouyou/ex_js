const String = @import("../String.zig");

const CodeUnitIterator = @This();

index: u32,
string: *const String,

pub fn next(self: *CodeUnitIterator) ?u16 {
    if (self.index >= self.string.length) return null;
    defer self.index += 1;
    return self.string.codeUnitAt(self.index);
}

pub fn previous(self: *CodeUnitIterator) ?u16 {
    if (self.index == 0) return null;
    defer self.index -= 1;
    return self.string.codeUnitAt(self.index);
}
