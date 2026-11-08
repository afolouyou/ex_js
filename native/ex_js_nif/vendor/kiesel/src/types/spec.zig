const data_block = @import("spec/data_block.zig");
const disposable = @import("spec/disposable.zig");
const iterator = @import("spec/iterator.zig");

pub const Arguments = @import("spec/Arguments.zig");
pub const ClassFieldDefinition = @import("spec/ClassFieldDefinition.zig");
pub const ClassStaticBlockDefinition = @import("spec/ClassStaticBlockDefinition.zig");
pub const DataBlock = data_block.DataBlock;
pub const DisposableResource = disposable.DisposableResource;
pub const Iterator = iterator.Iterator;
pub const IteratorKind = iterator.IteratorKind;
pub const PrivateElement = @import("spec/private_element.zig").PrivateElement;
pub const PrivateMethodDefinition = @import("spec/PrivateMethodDefinition.zig");
pub const PrivateName = @import("spec/PrivateName.zig");
pub const PropertyDescriptor = @import("spec/PropertyDescriptor.zig");
pub const addDisposableResource = disposable.addDisposableResource;
pub const copyDataBlockBytes = data_block.copyDataBlockBytes;
pub const createByteDataBlock = data_block.createByteDataBlock;
pub const createDisposableResource = disposable.createDisposableResource;
pub const createIteratorResultObject = iterator.createIteratorResultObject;
pub const createSharedByteDataBlock = data_block.createSharedByteDataBlock;
pub const disposeResources = disposable.disposeResources;
pub const getDisposeMethod = disposable.getDisposeMethod;
pub const getIterator = iterator.getIterator;
pub const getIteratorDirect = iterator.getIteratorDirect;
pub const getIteratorFlattenable = iterator.getIteratorFlattenable;
pub const getIteratorFromMethod = iterator.getIteratorFromMethod;
pub const data_block_max_byte_length = data_block.data_block_max_byte_length;

test {
    _ = data_block;
    _ = iterator;

    _ = PropertyDescriptor;
}
