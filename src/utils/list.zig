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

/// Unlink the entry at `index`, keeping `fixup` pointed at the entry the
/// swapRemove moved into the hole so the caller can re-index it.
///
/// The registries that own an index per entry (the driver's sample lists) are
/// walked on every free, so a linear search per free made a game that allocates
/// and releases handles in a loop pay O(n^2) over its own churn. `fixup` is
/// called only when the removed entry was not the last one, which is the only
/// case where a different entry moved; it is not called at all for an
/// out-of-range index.
pub fn removeAt(list: anytype, index: usize, fixup: anytype) void {
    if (index >= list.items.len) return;
    const moved: ?@TypeOf(list.items[0]) = if (index + 1 < list.items.len) list.items[list.items.len - 1] else null;
    _ = list.swapRemove(index);
    if (moved) |m| fixup(m, index);
}
