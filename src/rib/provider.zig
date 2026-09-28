//! RIB plugin/provider registry. A Provider wraps a loadable codec module
//! (.asi/.m3d/.flt) and the interfaces it registers; this is the broker the
//! AIL_* / RIB_* surface uses to enumerate and dispatch into plugins.

const std = @import("std");
const root = @import("../root.zig");
const ma = root.ma;
const tsf = root.tsf;
const log = root.log;
const fs_compat = root.fs_compat;

pub const RIB_ENTRY_TYPE = enum(u32) {
    RIB_FUNCTION = 0,
    RIB_ATTRIBUTE = 1,
};

pub const RIB_INTERFACE_ENTRY = extern struct {
    entry_type: RIB_ENTRY_TYPE,
    name: [*c]const u8,
    token: usize,
    subtype: u32,
};

/// Ceiling on the entry count one `RIB_register_interface` call may declare.
/// The count is the loaded module's, and the array it names is the module's
/// too, so nothing here bounds what a plugin walks; without a ceiling a single
/// absurd count drives one name dupe and one hash insert per entry, growing
/// the interface by that many entries before anything else can object. Real
/// interfaces (ASI codecs, DLS providers) hold tens.
const max_interface_entries: i32 = 65536;

pub const RIB_alloc_provider_handle_ptr = *const fn (i32) callconv(.c) HPROVIDER;

pub const RIB_register_interface_ptr = *const fn (HPROVIDER, [*c]const u8, i32, [*c]RIB_INTERFACE_ENTRY) callconv(.c) usize;

pub const RIB_unregister_interface_ptr = *const fn (usize) callconv(.c) void;

pub const RIB_Main_ptr = *const fn (HPROVIDER, u32, RIB_alloc_provider_handle_ptr, RIB_register_interface_ptr, RIB_unregister_interface_ptr) callconv(.c) i32;

// The provider whose RIB_Main is running right now, so the three callbacks a
// plugin receives can answer "which provider am I registering into" without the
// plugin having to thread that through itself. Thread-local, not a global: the
// plugin's RIB_Main runs synchronously on the thread that called Provider.load,
// so a process-wide slot let a second thread loading a provider concurrently
// overwrite this one, and the first plugin's RIB_alloc_provider_handle then
// handed back the *other* provider's handle -- its interfaces would register
// into a provider that is about to be released.
threadlocal var current_loading_provider: ?*Provider = null;

pub fn getCurrentLoadingProvider() ?*Provider {
    return current_loading_provider;
}

fn rib_alloc_provider_handle(module: i32) callconv(.c) HPROVIDER {
    _ = module;
    if (current_loading_provider) |p| return p.handle;
    return null;
}

fn rib_register_interface(provider_handle: HPROVIDER, name: [*c]const u8, entry_count: i32, entries: [*c]RIB_INTERFACE_ENTRY) callconv(.c) usize {
    if (provider_handle) |ptr| {
        const p: *Provider = @ptrCast(@alignCast(ptr));
        const z_name = std.mem.span(name);
        const iface = p.registerInterface(z_name, entry_count, entries) catch |err| {
            log("rib_register_interface: failed for '{s}': {any}\n", .{ z_name, err });
            // Report failure to the plugin: a handle here tells it the entries are
            // registered, so it will dispatch through tokens that were never
            // stored (an OOM inside registerInterface drops them all).
            return 0;
        };
        return @intCast(iface.handle);
    }
    return 0;
}

/// Drop the interface the plugin holds the handle for. A plugin unregisters
/// through the callback it was handed at registration, so without this its
/// shutdown left every entry of the interface in the registry: a later
/// RIB_request_interface or AIL_ASI_provider_attribute still resolved a token
/// for an interface the module had already torn down.
///
/// The handle is resolved against the thread's loading provider, the one the
/// registration went into, so a handle cannot unregister another provider's
/// interface. A handle that names nothing is a no-op: a plugin that
/// unregisters the same interface twice changes nothing the second time.
fn rib_unregister_interface(handle: usize) callconv(.c) void {
    const p = current_loading_provider orelse return;
    p.unregisterInterfaceHandle(handle);
}

pub const Provider = struct {
    handle: HPROVIDER,
    lib: ?root.DynLib,
    name: [:0]const u8,
    allocator: std.mem.Allocator,
    interfaces: std.ArrayListUnmanaged(*Interface),
    // Owned path of a temp file this Provider was loaded from (e.g. the
    // in-memory ASI image AIL_open_ASI_provider writes to disk). Deleted when
    // the provider is released, after the module is unloaded and the OS lets
    // go of the file; null for providers loaded from real on-disk plugins.
    temp_path: ?[:0]u8 = null,
    // The resolved path the module was loaded from, or null for a provider
    // that was never loaded from a file. This is the identity a second load of
    // the same plugin is matched against, so a rescan of a directory cannot
    // register one module twice.
    source_path: ?[:0]u8 = null,
    // The image this provider was opened from (AIL_open_ASI_provider), and the
    // opens of it that no close has answered yet. Null for a provider loaded
    // from a file on disk. See publishImage / releaseImage.
    image_key: ?ImageKey = null,
    image_refs: u32 = 0,
    user_data: [8]usize = [_]usize{0} ** 8,
    system_data: [8]usize = [_]usize{0} ** 8,
    // Source of the interface handles handed to the plugin. Monotonic and
    // never reused, so a handle a plugin still holds cannot name a different
    // interface registered after the one it was given. Same width as the
    // `Interface.handle` it is stored in and the `usize` a plugin hands back to
    // unregister, which is a token compared against pointers and so is
    // pointer-width; a u64 counter does not fit that on a 32-bit target.
    next_handle: usize = 1,

    pub fn init(allocator: std.mem.Allocator) !*Provider {
        log("Provider.init called\n", .{});
        const name = try allocator.dupeZ(u8, "unknown");
        errdefer allocator.free(name);
        const self = try allocator.create(Provider);
        errdefer allocator.destroy(self);
        self.* = .{
            .handle = @ptrCast(self),
            .lib = null,
            .name = name,
            .allocator = allocator,
            .interfaces = .empty,
        };
        return self;
    }

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !*Provider {
        const self = try allocator.create(Provider);
        // Cover every fallible step from here on: the dupeZ below can fail while
        // self is allocated but uninitialized, so the guard must precede it.
        errdefer allocator.destroy(self);
        const name = try allocator.dupeZ(u8, std.fs.path.basename(path));
        errdefer allocator.free(name);
        var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
        const resolved_path = fs_compat.maybeResolveCaseInsensitivePath(path, &resolved_buf) orelse path;
        const source = try allocator.dupeZ(u8, resolved_path);
        errdefer allocator.free(source);
        self.* = .{
            .handle = @ptrCast(self),
            .lib = null,
            .name = name,
            .allocator = allocator,
            .interfaces = .empty,
            .source_path = source,
        };

        const prev = current_loading_provider;
        current_loading_provider = self;
        defer current_loading_provider = prev;

        var lib = try root.DynLib.open(resolved_path);
        self.lib = lib;
        errdefer {
            lib.close();
            self.lib = null;
        }

        if (lib.lookup(RIB_Main_ptr, "RIB_Main")) |rib_main| {
            // The plugin's own status for the load. It is not a load failure by
            // itself (a plugin may return its own convention), but a provider
            // whose RIB_Main reported failure and registered nothing would
            // otherwise sit in the registry looking loaded, and every later
            // lookup would report the interface as simply absent.
            const status = rib_main(self.handle, 1, rib_alloc_provider_handle, rib_register_interface, rib_unregister_interface);
            if (status == 0) {
                log("Provider.load: RIB_Main in '{s}' reported failure (returned 0)\n", .{name});
            }
            if (self.interfaces.items.len == 0) {
                log("Provider.load: '{s}' registered no interfaces\n", .{name});
            }
        } else {
            // A module that opened but exports no RIB_Main cannot register
            // anything, and the load reports success: the scan counts it, the
            // provider is adopted, and every interface query answers "absent"
            // with nothing anywhere saying why. Name the module, since the
            // operator is looking at a plugin that "loaded" and does nothing.
            log("Provider.load: '{s}' exports no RIB_Main; it is loaded but registers no interface\n", .{name});
        }

        return self;
    }

    pub fn deinit(self: *Provider) void {
        // Out of the open-image registry before anything else: whatever frees
        // this provider, a later open of the same bytes must not be answered
        // with it. The close path (AIL_close_ASI_provider) has already taken the
        // last reference by the time it gets here, and this covers every other
        // route, including one that frees it while an open is still out.
        g_image_mutex.lockUncancelable(root.io);
        self.unlinkFromImageRegistryLocked();
        g_image_mutex.unlock(root.io);
        if (self.lib) |*lib| {
            if (lib.lookup(RIB_Main_ptr, "RIB_Main")) |rib_main| {
                // The unload RIB_Main gets the same "which provider am I"
                // context the load one does. Without it a plugin that
                // unregisters through RIB_unregister_interface resolves the
                // handle against whatever provider happened to be loading on
                // this thread, or against null.
                const prev = current_loading_provider;
                current_loading_provider = self;
                defer current_loading_provider = prev;
                // Shutdown is a notification: nothing is loaded afterwards that
                // a status could change, but a plugin that could not shut down
                // cleanly may still be running teardown state, so a reported
                // failure is worth saying out loud.
                if (rib_main(self.handle, 0, rib_alloc_provider_handle, rib_register_interface, rib_unregister_interface) == 0) {
                    log("Provider.deinit: RIB_Main in '{s}' reported failure while unloading\n", .{self.name});
                }
            }
            lib.close();
        }
        // The module is unloaded, so the temp image file is unlocked and can go.
        // (Deleting before FreeLibrary would fail on Windows, which locks loaded
        // DLLs — the leak that accumulated one temp file per AIL_open_ASI_provider.)
        if (self.temp_path) |tmp| {
            // A delete that fails leaves the extracted image on disk for the
            // life of the host process, and the path is freed below, so nothing
            // can ever retry it. Say so instead of dropping the file silently.
            fs_compat.deleteFile(root.io, tmp) catch |err| {
                root.log("Provider.deinit: cannot delete temp image '{s}' ({any}); the file stays on disk\n", .{ tmp, err });
            };
            self.allocator.free(tmp);
            self.temp_path = null;
        }
        for (self.interfaces.items) |iface| {
            iface.deinit();
        }
        self.interfaces.deinit(self.allocator);
        if (self.source_path) |sp| self.allocator.free(sp);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    /// Removes every interface registered under `name`, keeping the order of
    /// the rest. A plugin that registered one name more than once gets all of
    /// them dropped: stopping at the first would leave a copy that keeps
    /// answering entry lookups after the interface was unregistered, so the
    /// second unregister would still change state.
    pub fn unregisterInterface(self: *Provider, name: []const u8) void {
        var i: usize = 0;
        while (i < self.interfaces.items.len) {
            const iface = self.interfaces.items[i];
            if (std.mem.eql(u8, iface.name, name)) {
                iface.deinit();
                _ = self.interfaces.orderedRemove(i);
                continue;
            }
            i += 1;
        }
    }

    /// Removes the one interface `handle` names, the path a plugin takes
    /// through the unregister callback it was handed at registration. Drops
    /// only that interface, unlike unregisterInterface by name, because a
    /// handle is specific to one registration.
    pub fn unregisterInterfaceHandle(self: *Provider, handle: usize) void {
        for (self.interfaces.items, 0..) |iface, i| {
            if (iface.handle == handle) {
                iface.deinit();
                _ = self.interfaces.orderedRemove(i);
                return;
            }
        }
    }

    /// Register `name` and return the stored interface, whose `handle` is what
    /// RIB_unregister_interface takes.
    pub fn registerInterface(self: *Provider, name: []const u8, count: i32, entries: ?*anyopaque) !*Interface {
        log("Provider.registerInterface called: {s}, count={d}\n", .{ name, count });
        // A negative or absurd entry count comes from the plugin, not from us:
        // rejecting it silently would hand back an empty interface the plugin
        // believes it filled.
        if (count < 0) {
            log("Provider.registerInterface: '{s}' declared {d} entries\n", .{ name, count });
            return error.NegativeEntryCount;
        }
        if (count > max_interface_entries) {
            log("Provider.registerInterface: '{s}' declared {d} entries, over the {d} ceiling\n", .{ name, count, max_interface_entries });
            return error.TooManyEntries;
        }
        // A plugin may pass entries == NULL with a positive count; the cast
        // below would then walk a null array.
        if (entries == null and count > 0) {
            log("Provider.registerInterface: '{s}' declared {d} entries with no array\n", .{ name, count });
            return error.MissingEntryArray;
        }
        const entry_count: usize = @intCast(count);
        const iface = try Interface.init(self.allocator, name);
        // Own the interface until it is safely appended to the provider list:
        // an OOM partway through the entry loop must not leak it (or the entry
        // names duped so far).
        errdefer iface.deinit();
        const rib_entries: [*]WireInterfaceEntry = if (entry_count == 0) undefined else @ptrCast(@alignCast(entries.?));
        var i: usize = 0;
        while (i < entry_count) : (i += 1) {
            const entry = rib_entries[i];
            if (entry.name != null) {
                try iface.add(std.mem.span(entry.name), entry.token, entryTypeFromWire(entry.entry_type), entry.subtype);
            }
        }
        // A counter that wrapped would hand out a handle an earlier interface
        // already had, which is the reuse the counter exists to prevent.
        if (self.next_handle == std.math.maxInt(usize)) return error.InterfaceHandlesExhausted;
        iface.handle = self.next_handle;
        self.next_handle += 1;
        try self.interfaces.append(self.allocator, iface);
        return iface;
    }

    /// How many images are open right now. Not an SDK surface: the test suite
    /// reads it to prove a second open of one image left one module behind, and
    /// that a close of every open empties the registry.
    pub fn openImageCount() usize {
        g_image_mutex.lockUncancelable(root.io);
        defer g_image_mutex.unlock(root.io);
        return g_image_providers.items.len;
    }

    /// The identity an in-memory plugin image is opened under, from its bytes.
    pub fn imageKeyOf(image: []const u8) ImageKey {
        return .{
            .lo = std.hash.Wyhash.hash(0, image),
            .hi = std.hash.Wyhash.hash(0x9e3779b97f4a7c15, image),
        };
    }

    /// True when `path` names a module this provider was already loaded from.
    /// The comparison is exact, so callers pass the resolved form (see
    /// fs_compat.maybeResolveCaseInsensitivePath) and a differently cased name
    /// on Windows is the same plugin.
    pub fn matchesSourcePath(self: *const Provider, path: []const u8) bool {
        const sp = self.source_path orelse return false;
        return std.mem.eql(u8, sp, path);
    }

    /// Publish this provider as the one for the image `key` names, or hand
    /// back the provider already loaded from those bytes with a reference
    /// taken for this open. The caller unloads the copy it built and returns
    /// the one this returns.
    ///
    /// The whole check-then-act pair runs under one lock, which is what makes
    /// two opens of one image one module: writing the temp image and running
    /// the plugin's RIB_Main takes arbitrarily long, so two threads opening
    /// the same image both get past any check made before it. A registry that
    /// could not be consulted until after the module was loaded would have
    /// already paid for the second copy, which is what this answers for.
    pub fn publishImage(self: *Provider, key: ImageKey) *Provider {
        g_image_mutex.lockUncancelable(root.io);
        defer g_image_mutex.unlock(root.io);
        for (g_image_providers.items) |p| {
            if (p.image_key) |k| {
                if (std.meta.eql(k, key)) {
                    p.image_refs += 1;
                    return p;
                }
            }
        }
        self.image_key = key;
        self.image_refs = 1;
        g_image_providers.append(image_registry_alloc, self) catch {
            // Untracked, but still answerable by the handle the caller holds:
            // this open is a real provider, and the only thing lost is that a
            // later open of the same image builds a second copy. Say so rather
            // than fail an open that succeeded.
            root.log("Provider.publishImage: cannot track the image provider; a repeated open of these bytes will load the module again\n", .{});
        };
        return self;
    }

    /// Drop one open of an in-memory image and report whether that was the
    /// last one, which is when the module is unloaded and its temp image
    /// deleted. A provider with no image (loaded from a file, or never
    /// published) reports true straight away, so the close of one is the close
    /// of the other.
    pub fn releaseImage(self: *Provider) bool {
        g_image_mutex.lockUncancelable(root.io);
        defer g_image_mutex.unlock(root.io);
        if (self.image_key == null) return true;
        if (self.image_refs > 1) {
            self.image_refs -= 1;
            return false;
        }
        self.unlinkFromImageRegistryLocked();
        return true;
    }

    /// Take this provider out of the open-image registry, whether that was the
    /// last close or a teardown freeing it outright. Leaving a freed provider
    /// in the list would let the next open of those bytes be handed the freed
    /// one. The caller holds g_image_mutex.
    fn unlinkFromImageRegistryLocked(self: *Provider) void {
        for (g_image_providers.items, 0..) |p, i| {
            if (p == self) {
                _ = g_image_providers.swapRemove(i);
                break;
            }
        }
        self.image_key = null;
        self.image_refs = 0;
    }
};

/// One registered entry. `name` is a NUL-terminated copy owned by the
/// Interface and pointed at by `index`, so its address stays fixed for the
/// interface's lifetime: a rehash moves a hash map's own key storage, and
/// RIB_enumerate_interface hands the name to C callers as a `*c` string that
/// they are entitled to keep reading.
pub const InterfaceEntry = struct {
    name: [:0]u8,
    token: usize,
    entry_type: RIB_ENTRY_TYPE,
    subtype: u32,
};

pub const Interface = struct {
    name: []const u8,
    /// Entries in the order the provider registered them. RIB_enumerate_interface
    /// walks this, never `index`: hash-bucket order is a function of the key
    /// bytes and the map's rehash history, so two runs that register the same
    /// entries enumerate them in different orders and a recorded run cannot be
    /// replayed entry-for-entry.
    order: std.ArrayListUnmanaged(InterfaceEntry) = .empty,
    /// entry name -> index into `order`, for the O(1) lookups done by
    /// RIB_request_interface_entry and AIL_ASI_provider_attribute. The token
    /// lives only in `order`, so the two containers cannot disagree.
    index: std.StringHashMapUnmanaged(usize) = .empty,
    allocator: std.mem.Allocator,
    /// What RIB_unregister_interface takes to drop this registration. Assigned
    /// by Provider.registerInterface from a per-provider counter, so it is
    /// unique among the interfaces that provider holds and is never reused.
    handle: usize = 0,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !*Interface {
        const duped = try allocator.dupe(u8, name);
        errdefer allocator.free(duped);
        const self = try allocator.create(Interface);
        // The name dupe below can fail while self is allocated but
        // uninitialized, so the destroy guard must precede it.
        errdefer allocator.destroy(self);
        self.* = .{
            .name = duped,
            .allocator = allocator,
        };
        return self;
    }

    /// Adds an entry, or updates the token, type, and subtype of an
    /// already-registered name in place so the first registration keeps its
    /// position in the enumeration. One name is one entry: a later registration
    /// of the same name replaces what the earlier one stored.
    pub fn add(self: *Interface, name: []const u8, token: usize, entry_type: RIB_ENTRY_TYPE, subtype: u32) !void {
        if (self.index.get(name)) |existing| {
            self.order.items[existing].token = token;
            self.order.items[existing].entry_type = entry_type;
            self.order.items[existing].subtype = subtype;
            return;
        }
        const duped = try self.allocator.dupeZ(u8, name);
        errdefer self.allocator.free(duped);
        try self.order.append(self.allocator, .{
            .name = duped,
            .token = token,
            .entry_type = entry_type,
            .subtype = subtype,
        });
        errdefer _ = self.order.pop();
        try self.index.put(self.allocator, duped, self.order.items.len - 1);
    }

    pub fn tokenFor(self: *const Interface, name: []const u8) ?usize {
        const i = self.index.get(name) orelse return null;
        return self.order.items[i].token;
    }

    /// The token for `name` when that entry was registered as `want`, or null
    /// when the name is absent or was registered as the other type. A function
    /// and an attribute can share a name; the caller's type argument is the
    /// filter, and a name match of the wrong type is a miss.
    pub fn tokenForType(self: *const Interface, name: []const u8, want: RIB_ENTRY_TYPE) ?usize {
        const i = self.index.get(name) orelse return null;
        const entry = self.order.items[i];
        if (entry.entry_type != want) return null;
        return entry.token;
    }

    /// The `i`th entry in registration order, or null past the end.
    pub fn entryAt(self: *const Interface, i: usize) ?InterfaceEntry {
        if (i >= self.order.items.len) return null;
        return self.order.items[i];
    }

    pub fn deinit(self: *Interface) void {
        for (self.order.items) |entry| self.allocator.free(entry.name);
        self.order.deinit(self.allocator);
        self.index.deinit(self.allocator);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }
};

pub const HPROVIDER = ?*anyopaque;

/// Identity of an in-memory plugin image, and the key the open registry dedups
/// on. Two 64-bit hashes over the whole image: the same bytes are the same
/// module however they were reached, and a different image that happened to
/// land on the address an earlier one used is not the same module, so the key
/// is the content and not the caller's buffer pointer. A hash is used rather
/// than a byte compare so the registry holds no copy of every image it has
/// seen; two independent hashes is what makes a collision, which would hand
/// back the wrong module, out of reach.
pub const ImageKey = struct {
    lo: u64,
    hi: u64,
};

// Providers currently open from an in-memory image. One entry per live open
// group, not per open: a retried open of one image (a game that re-opens after
// a failed query, a wrapper that opens to check and opens again) is answered
// from here with the module already loaded, where every other load path in
// this engine dedups on identity (a resolved plugin path, a soundbank file, a
// soundfont). Bounded by the live providers, since the entry goes when the
// last close answers it. The backing store uses a process-stable allocator,
// independent of the provider's own (which in tests is the leak-checked test
// allocator), for the reason soundbank's registry does: the list outlives any
// one provider, and the test allocator would report its capacity as a leak.
var g_image_providers: std.ArrayListUnmanaged(*Provider) = .empty;
const image_registry_alloc = std.heap.page_allocator;
var g_image_mutex: std.Io.Mutex = .init;

/// The same record as a loaded module writes it, with the entry type as the
/// raw U32 the mss.h field is. `RIB_INTERFACE_ENTRY.entry_type` is a Zig enum,
/// and its two declared variants are the only valid values of that type: an
/// array a plugin filled in holds whatever it wrote, so reading the field as
/// the enum and then comparing it (tokenForType, RIB_enumerate_interface)
/// operates on a value the type does not admit, which is undefined behavior
/// and lets a module hand the whole registry a type field it never validated.
/// The entry array crosses into the process from the module, so it is read
/// through this view and the value is turned into an enum at the boundary.
///
/// Declared at the end of the file, past every line docs/THREAT_MODEL.md
/// anchors into this one, so adding it moves no anchor.
const WireInterfaceEntry = extern struct {
    entry_type: u32,
    name: [*c]const u8,
    token: usize,
    subtype: u32,
};

comptime {
    // The wire view exists only to re-type one field, so it has to agree with
    // the record it replaces in every other respect: a layout that drifted
    // would read a plugin's token and name from the wrong offsets.
    if (@sizeOf(WireInterfaceEntry) != @sizeOf(RIB_INTERFACE_ENTRY) or
        @offsetOf(WireInterfaceEntry, "name") != @offsetOf(RIB_INTERFACE_ENTRY, "name") or
        @offsetOf(WireInterfaceEntry, "token") != @offsetOf(RIB_INTERFACE_ENTRY, "token") or
        @offsetOf(WireInterfaceEntry, "subtype") != @offsetOf(RIB_INTERFACE_ENTRY, "subtype"))
    {
        @compileError("WireInterfaceEntry layout drifted from RIB_INTERFACE_ENTRY");
    }
}

/// The entry type a plugin's raw U32 names, or the SDK's function default for
/// anything else. The same spelling the RIB_* entry points use for their
/// `entry_type` argument, so a module that passes 1 for an attribute and a
/// module that passes anything else for a function agree.
fn entryTypeFromWire(value: u32) RIB_ENTRY_TYPE {
    return if (value == @intFromEnum(RIB_ENTRY_TYPE.RIB_ATTRIBUTE)) .RIB_ATTRIBUTE else .RIB_FUNCTION;
}
