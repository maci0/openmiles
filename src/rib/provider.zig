const std = @import("std");
const root = @import("../root.zig");
const ma = root.ma;
const tsf = root.tsf;
const log = root.log;
const fs_compat = root.fs_compat;

pub const RIB_DATA_TYPE = enum(u32) {
    RIB_NONE = 0,
    RIB_DEC = 1,
    RIB_HEX = 2,
    RIB_FLOAT = 3,
    RIB_PERCENT = 4,
    RIB_BOOL = 5,
    RIB_STRING = 6,
    RIB_READONLY = 0x80000000,
};

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
        p.registerInterface(z_name, entry_count, entries) catch {};
        return 1;
    }
    return 0;
}

fn rib_unregister_interface(handle: usize) callconv(.c) void {
    _ = handle;
}

pub const Provider = struct {
    handle: HPROVIDER,
    lib: ?std.DynLib,
    name: [:0]const u8,
    allocator: std.mem.Allocator,
    interfaces: std.ArrayListUnmanaged(*Interface),
    user_data: [8]usize = [_]usize{0} ** 8,
    system_data: [8]usize = [_]usize{0} ** 8,

    pub fn init(allocator: std.mem.Allocator, module: ?*anyopaque) !*Provider {
        log("Provider.init called\n", .{});
        const self = try allocator.create(Provider);
        self.* = .{
            .handle = @ptrCast(self),
            .lib = null,
            .name = try allocator.dupeZ(u8, "unknown"),
            .allocator = allocator,
            .interfaces = .{},
        };
        _ = module;
        return self;
    }

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !*Provider {
        const self = try allocator.create(Provider);
        self.* = .{
            .handle = @ptrCast(self),
            .lib = null,
            .name = try allocator.dupeZ(u8, std.fs.path.basename(path)),
            .allocator = allocator,
            .interfaces = .{},
        };
        errdefer {
            self.interfaces.deinit(allocator);
            allocator.free(self.name);
            allocator.destroy(self);
        }

        const prev = current_loading_provider;
        current_loading_provider = self;
        defer current_loading_provider = prev;

        var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
        const resolved_path = fs_compat.maybeResolveCaseInsensitivePath(path, &resolved_buf) orelse path;
        var lib = try std.DynLib.open(resolved_path);
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
        const iface = try Interface.init(self.allocator, name);
        const rib_entries: [*]RIB_INTERFACE_ENTRY = @ptrCast(@alignCast(entries));
        var i: usize = 0;
        while (i < @as(usize, @intCast(count))) : (i += 1) {
            const entry = rib_entries[i];
            // dupeZ so key.ptr can be safely used as a null-terminated C string in RIB_enumerate_interface
            if (entry.name != null) {
                const name_span = std.mem.span(entry.name);
                const duped = try self.allocator.dupeZ(u8, name_span);
                try iface.entries.put(self.allocator, duped, entry.token);
            }
        }
        try self.interfaces.append(self.allocator, iface);
    }
};

pub const Interface = struct {
    name: []const u8,
    entries: std.StringHashMapUnmanaged(usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !*Interface {
        const self = try allocator.create(Interface);
        self.* = .{
            .name = try allocator.dupe(u8, name),
            .entries = .{},
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *Interface) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            const z_ptr: [*:0]const u8 = @ptrCast(entry.key_ptr.*.ptr);
            self.allocator.free(z_ptr[0..entry.key_ptr.*.len :0]);
        }
        self.entries.deinit(self.allocator);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }
};

pub const HPROVIDER = ?*anyopaque;
