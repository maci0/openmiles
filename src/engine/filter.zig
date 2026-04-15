const std = @import("std");
const root = @import("../root.zig");
const ma = root.ma;
const log = root.log;

/// MSS Filter handle backed by miniaudio's ma_lpf_node for low-pass filtering.
/// Filters are created via AIL_open_filter and attached to samples via
/// AIL_set_sample_filter. When attached, the sample's audio routes through
/// the filter node before reaching the engine endpoint.
pub const Filter = struct {
    provider: *root.Provider,
    driver: *root.DigitalDriver,
    allocator: std.mem.Allocator,
    lpf_node: ma.ma_lpf_node,
    lpf_initialized: bool = false,
    cutoff_frequency: f64 = 22050.0, // Hz — fully open by default
    order: u32 = 2, // 2nd-order = 12dB/octave rolloff
    // Track which samples are routed through this filter for cleanup
    attached_samples: std.ArrayListUnmanaged(*root.Sample),

    /// If true, this filter is being torn down as part of DigitalDriver.deinit.
    /// In that path we skip updating the driver's filters list (which is being
    /// cleared anyway) and avoid touching the engine (already uninit'd).
    driver_is_dead: bool = false,

    pub fn init(provider: *root.Provider, driver: *root.DigitalDriver) !*Filter {
        const self = try driver.allocator.create(Filter);
        self.* = .{
            .provider = provider,
            .driver = driver,
            .allocator = driver.allocator,
            .lpf_node = undefined,
            .attached_samples = .{},
        };
        errdefer driver.allocator.destroy(self);
        try self.initLpfNode();
        errdefer ma.ma_lpf_node_uninit(&self.lpf_node, null);
        try driver.filters.append(driver.allocator, self);
        return self;
    }

    fn initLpfNode(self: *Filter) !void {
        const sample_rate = ma.ma_engine_get_sample_rate(&self.driver.engine);
        const channels = ma.ma_engine_get_channels(&self.driver.engine);
        const config = ma.ma_lpf_node_config_init(channels, sample_rate, self.cutoff_frequency, self.order);
        const result = ma.ma_lpf_node_init(
            @ptrCast(&self.driver.engine),
            &config,
            null,
            &self.lpf_node,
        );
        if (result != ma.MA_SUCCESS) {
            log("Filter.initLpfNode failed: {d}\n", .{result});
            return error.FilterInitFailed;
        }
        // Connect filter output to the engine endpoint
        const attach_result = ma.ma_node_attach_output_bus(
            @ptrCast(&self.lpf_node),
            0,
            ma.ma_engine_get_endpoint(&self.driver.engine),
            0,
        );
        if (attach_result != ma.MA_SUCCESS) {
            log("Filter: failed to attach to endpoint: {d}\n", .{attach_result});
            ma.ma_lpf_node_uninit(&self.lpf_node, null);
            return error.FilterAttachFailed;
        }
        self.lpf_initialized = true;
    }

    pub fn deinit(self: *Filter) void {
        // Unregister from driver's filter list so DigitalDriver.deinit doesn't
        // try to free us again. Skip if driver_is_dead (driver is already
        // iterating its filters list and will free us directly).
        if (!self.driver_is_dead) {
            for (self.driver.filters.items, 0..) |f, i| {
                if (f == self) {
                    _ = self.driver.filters.swapRemove(i);
                    break;
                }
            }
        }
        // Clear each attached sample's back-reference so they don't dangle.
        // Only re-route through the engine endpoint if the driver is still alive.
        for (self.attached_samples.items) |sample| {
            sample.attached_filter = null;
            if (!self.driver_is_dead and sample.is_initialized) {
                _ = ma.ma_node_attach_output_bus(
                    @ptrCast(&sample.sound),
                    0,
                    ma.ma_engine_get_endpoint(&self.driver.engine),
                    0,
                );
            }
        }
        self.attached_samples.deinit(self.allocator);
        if (self.lpf_initialized) {
            if (!self.driver_is_dead) {
                _ = ma.ma_node_detach_output_bus(@ptrCast(&self.lpf_node), 0);
            }
            ma.ma_lpf_node_uninit(&self.lpf_node, null);
        }
        self.allocator.destroy(self);
    }

    /// Attach a sample's audio output to route through this filter.
    pub fn attachSample(self: *Filter, sample: *root.Sample) void {
        if (!self.lpf_initialized or !sample.is_initialized) return;
        // Idempotent: if already attached to this filter, no-op.
        if (sample.attached_filter == self) return;
        // If attached to a different filter, detach from that one first so
        // the attached_samples lists stay consistent.
        if (sample.attached_filter) |prev| prev.detachSample(sample);
        // Route sample output → filter input (detaches from previous endpoint)
        const result = ma.ma_node_attach_output_bus(
            @ptrCast(&sample.sound),
            0,
            @ptrCast(&self.lpf_node),
            0,
        );
        if (result != ma.MA_SUCCESS) {
            log("Filter.attachSample failed: {d}\n", .{result});
            return;
        }
        // Track the sample for cleanup and set back-reference
        sample.attached_filter = self;
        self.attached_samples.append(self.allocator, sample) catch {
            log("Filter.attachSample: failed to track sample\n", .{});
        };
    }

    /// Detach a sample from this filter, routing it back to the engine endpoint.
    pub fn detachSample(self: *Filter, sample: *root.Sample) void {
        sample.attached_filter = null;
        if (sample.is_initialized) {
            _ = ma.ma_node_attach_output_bus(
                @ptrCast(&sample.sound),
                0,
                ma.ma_engine_get_endpoint(&self.driver.engine),
                0,
            );
        }
        // Remove from tracking list
        for (self.attached_samples.items, 0..) |s, i| {
            if (s == sample) {
                _ = self.attached_samples.swapRemove(i);
                break;
            }
        }
    }

    /// Set the low-pass cutoff frequency in Hz and reinitialize the filter.
    pub fn setCutoff(self: *Filter, frequency: f64) void {
        self.cutoff_frequency = @max(20.0, @min(frequency, 22050.0));
        if (self.lpf_initialized) {
            const sample_rate = ma.ma_engine_get_sample_rate(&self.driver.engine);
            const channels = ma.ma_engine_get_channels(&self.driver.engine);
            const config = ma.ma_lpf_config_init(
                ma.ma_format_f32,
                channels,
                sample_rate,
                self.cutoff_frequency,
                self.order,
            );
            _ = ma.ma_lpf_node_reinit(&config, &self.lpf_node);
        }
    }

    /// Get the current cutoff frequency.
    pub fn getCutoff(self: *const Filter) f64 {
        return self.cutoff_frequency;
    }

    /// Set a named attribute. Supported: "Cutoff" (Hz), "Order" (1-4).
    pub fn setAttribute(self: *Filter, name: []const u8, value: f32) void {
        if (std.ascii.eqlIgnoreCase(name, "cutoff")) {
            self.setCutoff(@floatCast(value));
        } else if (std.ascii.eqlIgnoreCase(name, "order")) {
            const new_order: u32 = @intFromFloat(@max(1.0, @min(value, 4.0)));
            if (new_order != self.order) {
                self.order = new_order;
                self.setCutoff(self.cutoff_frequency); // reinit with new order
            }
        } else {
            log("Filter.setAttribute: unknown attribute '{s}'\n", .{name});
        }
    }

    /// Get a named attribute value. Returns 0 for unknown attributes.
    pub fn getAttribute(self: *const Filter, name: []const u8) f32 {
        if (std.ascii.eqlIgnoreCase(name, "cutoff")) {
            return @floatCast(self.cutoff_frequency);
        } else if (std.ascii.eqlIgnoreCase(name, "order")) {
            return @floatFromInt(self.order);
        }
        return 0;
    }
};
