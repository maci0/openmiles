const std = @import("std");
const root = @import("../root.zig");
const ma = root.ma;
const log = root.log;

/// Fallback ceiling for the low-pass cutoff when the engine rate is unusable.
const DEFAULT_CUTOFF_HZ: f64 = 22050.0;

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
    cutoff_frequency: f64 = DEFAULT_CUTOFF_HZ, // Hz; initLpfNode replaces this with the driver Nyquist
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
            .attached_samples = .empty,
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
        // "Fully open" is the device's Nyquist, not a fixed 22050 Hz: MSS's
        // normalized 1.0 maps to cutoff * Nyquist (Sample.setLowPassNormalized),
        // so the untouched filter has to sit at the driver's Nyquist to make a
        // normalized cutoff of 1.0 mean "no filtering" on any sample rate.
        self.cutoff_frequency = @as(f64, @floatFromInt(@max(sample_rate, 2))) / 2.0;
        const config = ma.ma_lpf_node_config_init(channels, sample_rate, self.cutoff_frequency, self.order);
        const result = ma.ma_lpf_node_init(
            @ptrCast(&self.driver.engine),
            &config,
            null,
            &self.lpf_node,
        );
        if (result != ma.MA_SUCCESS) {
            log("Filter.initLpfNode failed: {d} ({s})\n", .{ result, root.maResultDescription(result) });
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
            log("Filter: failed to attach to endpoint: {d} ({s})\n", .{ attach_result, root.maResultDescription(attach_result) });
            ma.ma_lpf_node_uninit(&self.lpf_node, null);
            return error.FilterAttachFailed;
        }
        self.lpf_initialized = true;
    }

    pub fn deinit(self: *Filter) void {
        // Unregister from driver's filter list so DigitalDriver.deinit doesn't
        // try to free us again. Skip if driver_is_dead (driver is already
        // iterating its filters list and will free us directly).
        if (!self.driver_is_dead) root.removeFirst(&self.driver.filters, self);
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
        if (sample.attached_filter == self) return;
        // If attached to a different filter, detach from that one first so
        // the attached_samples lists stay consistent.
        if (sample.attached_filter) |prev| prev.detachSample(sample);
        const result = ma.ma_node_attach_output_bus(
            @ptrCast(&sample.sound),
            0,
            @ptrCast(&self.lpf_node),
            0,
        );
        if (result != ma.MA_SUCCESS) {
            log("Filter.attachSample failed: {d} ({s})\n", .{ result, root.maResultDescription(result) });
            return;
        }
        // Track the sample for cleanup BEFORE setting the back-reference: if the
        // tracking append fails, an attached_filter left pointing at this filter
        // would dangle once this Filter is deinit'd (Sample.deinit calls
        // attached_filter.detachSample). Also undo the audio re-route so the
        // sample never feeds a filter node that no longer knows about it.
        self.attached_samples.append(self.allocator, sample) catch {
            log("Filter.attachSample: failed to track sample\n", .{});
            _ = ma.ma_node_attach_output_bus(
                @ptrCast(&sample.sound),
                0,
                ma.ma_engine_get_endpoint(&self.driver.engine),
                0,
            );
            return;
        };
        sample.attached_filter = self;
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
        root.removeFirst(&self.attached_samples, sample);
    }

    /// Set the low-pass cutoff frequency in Hz and reinitialize the filter.
    pub fn setCutoff(self: *Filter, frequency: f64) void {
        // MSS's low-pass cutoff is a normalized 0..1 value (1.0 = fully open) and
        // Sample.setLowPassNormalized converts it with cutoff * Nyquist, so the
        // ceiling has to be the live engine rate's Nyquist: a fixed 22.05 kHz cap
        // clipped every cutoff above 0.919 on a 48 kHz (or higher) driver.
        // A zero or negative rate (uninitialized engine) falls back to that same
        // 22.05 kHz so the clamp still has a finite bound.
        const engine_rate = ma.ma_engine_get_sample_rate(&self.driver.engine);
        const nyquist: f64 = if (engine_rate > 0)
            @as(f64, @floatFromInt(engine_rate)) / 2.0
        else
            DEFAULT_CUTOFF_HZ;
        const clamped = if (std.math.isNan(frequency)) 1000.0 else @max(20.0, @min(frequency, nyquist));
        if (clamped == self.cutoff_frequency) return;
        self.cutoff_frequency = clamped;
        self.reinitLpf();
    }

    /// Rebuild the LPF node from the current cutoff and order. Both setters go
    /// through here so changing either one takes effect.
    fn reinitLpf(self: *Filter) void {
        if (!self.lpf_initialized) return;
        const engine_rate = ma.ma_engine_get_sample_rate(&self.driver.engine);
        const channels = ma.ma_engine_get_channels(&self.driver.engine);
        const config = ma.ma_lpf_config_init(
            ma.ma_format_f32,
            channels,
            engine_rate,
            self.cutoff_frequency,
            self.order,
        );
        _ = ma.ma_lpf_node_reinit(&config, &self.lpf_node);
    }

    /// Set a named attribute. Supported: "Cutoff" (Hz), "Order" (1-4).
    pub fn setAttribute(self: *Filter, name: []const u8, value: f32) void {
        if (std.ascii.eqlIgnoreCase(name, "cutoff")) {
            self.setCutoff(@floatCast(value));
        } else if (std.ascii.eqlIgnoreCase(name, "order")) {
            // Guard NaN (which would slip past @max/@min and panic @intFromFloat).
            const v: f32 = if (std.math.isNan(value)) 1.0 else @max(1.0, @min(value, 4.0));
            const new_order: u32 = @intFromFloat(v);
            if (new_order != self.order) {
                self.order = new_order;
                self.reinitLpf();
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
