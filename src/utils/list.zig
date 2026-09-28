//! Small container helpers shared by the engine's handle registries.
//!
//! A leaf module: nothing here touches engine state, so any layer may use it.

/// Drop the first entry equal to `item`, if the list holds one. The registries
/// that unlink through it hold distinct handles, so the first match is the only
/// one, and a miss is the normal outcome of a double unregister.
pub fn removeFirst(list: anytype, item: anytype) void {
    for (list.items, 0..) |entry, i| {
        if (entry == item) {
            _ = list.swapRemove(i);
            return;
        }
    }
}
