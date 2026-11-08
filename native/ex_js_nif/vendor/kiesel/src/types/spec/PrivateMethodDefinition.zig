//! Non-standard struct combining a private name and a private element.
//!
//! Most of the time private elements are stored in a hash map, so `PrivateElement` omits the
//! spec's [[Key]] field.

const types = @import("../../types.zig");

const PrivateElement = types.PrivateElement;
const PrivateName = types.PrivateName;

private_name: PrivateName,
private_element: PrivateElement,
