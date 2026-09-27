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

pub const RIB_alloc_provider_handle_ptr = *const fn (i32) callconv(.c) HPROVIDER;

pub const RIB_register_interface_ptr = *const fn (HPROVIDER, [*c]const u8, i32, [*c]RIB_INTERFACE_ENTRY) callconv(.c) usize;

pub const RIB_unregister_interface_ptr = *const fn (usize) callconv(.c) void;

pub const RIB_Main_ptr = *const fn (HPROVIDER, u32, RIB_alloc_provider_handle_ptr, RIB_register_interface_ptr, RIB_unregister_interface_ptr) callconv(.c) i32;

var current_loading_provider: ?*Provider = null;

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
        p.registerInterface(z_name, entry_count, entries) catch |err| {
            log("rib_register_interface: failed for '{s}': {any}\n", .{ z_name, err });
            // Report failure to the plugin: 1 here tells it the entries are
            // registered, so it will dispatch through tokens that were never
            // stored (an OOM inside registerInterface drops them all).
            return 0;
        };
        return 1;
    }
    return 0;
}

fn rib_unregister_interface(handle: usize) callconv(.c) void {
    _ = handle;
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
    user_data: [8]usize = [_]usize{0} ** 8,
    system_data: [8]usize = [_]usize{0} ** 8,

    pub fn init(allocator: std.mem.Allocator, module: ?*anyopaque) !*Provider {
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
        _ = module;
        return self;
    }

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !*Provider {
        const self = try allocator.create(Provider);
        // Cover every fallible step from here on: the dupeZ below can fail while
        // self is allocated but uninitialized, so the guard must precede it.
        errdefer allocator.destroy(self);
        const name = try allocator.dupeZ(u8, std.fs.path.basename(path));
        errdefer allocator.free(name);
        self.* = .{
            .handle = @ptrCast(self),
            .lib = null,
            .name = name,
            .allocator = allocator,
            .interfaces = .empty,
        };

        const prev = current_loading_provider;
        current_loading_provider = self;
        defer current_loading_provider = prev;

        var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
        const resolved_path = fs_compat.maybeResolveCaseInsensitivePath(path, &resolved_buf) orelse path;
        var lib = try root.DynLib.open(resolved_path);
        self.lib = lib;
        errdefer {
            lib.close();
            self.lib = null;
        }

        if (lib.lookup(RIB_Main_ptr, "RIB_Main")) |rib_main| {
            _ = rib_main(self.handle, 1, rib_alloc_provider_handle, rib_register_interface, rib_unregister_interface);
        }

        return self;
    }

    pub fn deinit(self: *Provider) void {
        if (self.lib) |*lib| {
            if (lib.lookup(RIB_Main_ptr, "RIB_Main")) |rib_main| {
                _ = rib_main(self.handle, 0, rib_alloc_provider_handle, rib_register_interface, rib_unregister_interface);
            }
            lib.close();
        }
        // The module is unloaded, so the temp image file is unlocked and can go.
        // (Deleting before FreeLibrary would fail on Windows, which locks loaded
        // DLLs — the leak that accumulated one temp file per AIL_open_ASI_provider.)
        if (self.temp_path) |tmp| {
            std.Io.Dir.deleteFileAbsolute(root.io, tmp) catch {
                std.Io.Dir.cwd().deleteFile(root.io, tmp) catch {};
            };
            self.allocator.free(tmp);
            self.temp_path = null;
        }
        for (self.interfaces.items) |iface| {
            iface.deinit();
        }
        self.interfaces.deinit(self.allocator);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    pub fn unregisterInterface(self: *Provider, name: []const u8) void {
        for (self.interfaces.items, 0..) |iface, i| {
            if (std.mem.eql(u8, iface.name, name)) {
                iface.deinit();
                _ = self.interfaces.swapRemove(i);
                break;
            }
        }
    }

    pub fn registerInterface(self: *Provider, name: []const u8, count: i32, entries: *anyopaque) !void {
        log("Provider.registerInterface called: {s}, count={d}\n", .{ name, count });
        // A negative entry count comes from the plugin, not from us: rejecting
        // it silently would hand back an empty interface the plugin believes
        // it filled.
        if (count < 0) {
            log("Provider.registerInterface: '{s}' declared {d} entries\n", .{ name, count });
            return error.NegativeEntryCount;
        }
        const entry_count: usize = @intCast(count);
        const iface = try Interface.init(self.allocator, name);
        // Own the interface until it is safely appended to the provider list:
        // an OOM partway through the entry loop must not leak it (or the entry
        // names duped so far).
        errdefer iface.deinit();
        const rib_entries: [*]RIB_INTERFACE_ENTRY = @ptrCast(@alignCast(entries));
        var i: usize = 0;
        while (i < entry_count) : (i += 1) {
            const entry = rib_entries[i];
            if (entry.name != null) {
                try iface.add(std.mem.span(entry.name), entry.token);
            }
        }
        try self.interfaces.append(self.allocator, iface);
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

    /// Adds an entry, or updates the token of an already-registered name in
    /// place so the first registration keeps its position in the enumeration.
    pub fn add(self: *Interface, name: []const u8, token: usize) !void {
        if (self.index.get(name)) |existing| {
            self.order.items[existing].token = token;
            return;
        }
        const duped = try self.allocator.dupeZ(u8, name);
        errdefer self.allocator.free(duped);
        try self.order.append(self.allocator, .{ .name = duped, .token = token });
        errdefer _ = self.order.pop();
        try self.index.put(self.allocator, duped, self.order.items.len - 1);
    }

    pub fn tokenFor(self: *const Interface, name: []const u8) ?usize {
        const i = self.index.get(name) orelse return null;
        return self.order.items[i].token;
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
