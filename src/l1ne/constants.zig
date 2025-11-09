//! Constants for L1NE orchestrator
//!
//! This module defines runtime limits that are read from Nix configuration files.
//! These limits determine exactly how much memory to allocate statically at startup.
//!
//! Design Philosophy (NASA/TigerBeetle):
//! - Everything has explicit bounds
//! - No dynamic growth - all limits known at startup
//! - Bounds create natural backpressure
//! - Memory usage is deterministic and calculable

const std = @import("std");
const types = @import("types.zig");
const assert = std.debug.assert;

/// Maximum limits - hard caps that cannot be exceeded
/// These are compile-time constants for safety
pub const max_service_instances: u8 = 64; // Maximum services per L1NE instance
pub const max_proxy_connections: u32 = 4096; // Maximum concurrent proxy connections
pub const max_proxy_pool_connections: u8 = 64; // Hardware-backed pool capacity
pub const max_proxy_buffer_size: u32 = 64 * types.KIB; // Maximum buffer per connection
pub const max_cgroup_monitors: u8 = 64; // Maximum cgroup monitors
pub const max_systemd_buffer_size: u32 = 16 * types.KIB; // Maximum systemd message buffer

/// Runtime limits read from Nix configuration
/// These determine actual memory allocation at startup
pub const RuntimeLimits = struct {
    /// Number of service instances to run
    /// Each service gets its own systemd unit and cgroup
    service_instances_count: u8,

    /// Maximum concurrent proxy connections
    /// When this limit is reached, new connections are rejected (backpressure)
    proxy_connections_max: u32,

    /// Size of read buffer per proxy connection (in bytes)
    /// Total proxy memory = proxy_connections_max × proxy_buffer_size
    proxy_buffer_size: u32,

    /// Number of cgroup monitors (typically one per service)
    cgroup_monitors_count: u8,

    /// Size of systemd notification/status message buffer
    systemd_buffer_size: u32,

    /// Validate limits against compile-time maximums
    pub fn validate(self: RuntimeLimits) !void {
        // Service instances validation
        assert(self.service_instances_count > 0); // Must have at least one service
        if (self.service_instances_count > max_service_instances) {
            return error.LimitExceeded;
        }

        // Proxy connections validation
        assert(self.proxy_connections_max > 0); // Must support at least one connection
        if (self.proxy_connections_max > max_proxy_connections) {
            return error.LimitExceeded;
        }

        // Proxy buffer size validation
        assert(self.proxy_buffer_size > 0); // Must have non-zero buffer
        if (self.proxy_buffer_size > max_proxy_buffer_size) {
            return error.LimitExceeded;
        }

        // Cgroup monitors validation
        assert(self.cgroup_monitors_count > 0); // Must monitor at least one cgroup
        if (self.cgroup_monitors_count > max_cgroup_monitors) {
            return error.LimitExceeded;
        }

        // Systemd buffer validation
        assert(self.systemd_buffer_size > 0); // Must have non-zero buffer
        if (self.systemd_buffer_size > max_systemd_buffer_size) {
            return error.LimitExceeded;
        }

        // Cross-validation: cgroup monitors should match service instances
        if (self.cgroup_monitors_count != self.service_instances_count) {
            std.log.warn("cgroup_monitors_count ({any}) != service_instances_count ({any})", .{
                self.cgroup_monitors_count,
                self.service_instances_count,
            });
            // This is a warning, not an error - valid to have different counts
        }
    }

    /// Calculate total memory footprint for these limits
    pub fn calculate_memory_usage(self: RuntimeLimits) u64 {
        var total: u64 = 0;

        // Service instances metadata
        // (Actual ServiceInstance struct size TBD, estimate ~512 bytes)
        const service_instance_size: u64 = 512;
        total += service_instance_size * self.service_instances_count;

        // Proxy connection metadata
        // (ProxyConnection struct estimate ~256 bytes)
        const proxy_connection_size: u64 = 256;
        total += proxy_connection_size * self.proxy_connections_max;

        // Proxy read buffers (the largest allocation)
        total += @as(u64, self.proxy_buffer_size) * self.proxy_connections_max;

        // Cgroup monitors
        // (CgroupMonitor struct estimate ~128 bytes)
        const cgroup_monitor_size: u64 = 128;
        total += cgroup_monitor_size * self.cgroup_monitors_count;

        // Systemd buffer
        total += self.systemd_buffer_size;

        // IOPs bitset overhead (minimal - one u64 per pool)
        const bitset_overhead = 8 * 4; // 4 pools × 8 bytes
        total += bitset_overhead;

        return total;
    }

    /// Format memory usage in human-readable form
    pub fn format_memory_usage(self: RuntimeLimits) void {
        const total = self.calculate_memory_usage();
        const mb = @as(f64, @floatFromInt(total)) / @as(f64, types.MIB);

        std.log.info("=== Static Memory Allocation ===", .{});
        std.log.info("Service instances:    {any} × ~512 B", .{self.service_instances_count});
        std.log.info("Proxy connections:    {any} × ~256 B", .{self.proxy_connections_max});
        std.log.info("Proxy buffers:        {any} × {any} B", .{
            self.proxy_connections_max,
            self.proxy_buffer_size,
        });
        std.log.info("Cgroup monitors:      {any} × ~128 B", .{self.cgroup_monitors_count});
        std.log.info("Systemd buffer:       {any} B", .{self.systemd_buffer_size});
        std.log.info("Total:                {d:.2} MiB", .{mb});
        std.log.info("================================", .{});
    }
};

/// Default configuration for development/testing
/// Production should always read from Nix config
pub const default_limits = RuntimeLimits{
    .service_instances_count = 4,
    .proxy_connections_max = 256,
    .proxy_buffer_size = 4 * types.KIB,
    .cgroup_monitors_count = 4,
    .systemd_buffer_size = 4 * types.KIB,
};

// Compile-time validation of defaults
comptime {
    // Ensure defaults are within maximums
    assert(default_limits.service_instances_count <= max_service_instances);
    assert(default_limits.proxy_connections_max <= max_proxy_connections);
    assert(default_limits.proxy_buffer_size <= max_proxy_buffer_size);
    assert(default_limits.cgroup_monitors_count <= max_cgroup_monitors);
    assert(default_limits.systemd_buffer_size <= max_systemd_buffer_size);

    // Ensure all defaults are non-zero
    assert(default_limits.service_instances_count > 0);
    assert(default_limits.proxy_connections_max > 0);
    assert(default_limits.proxy_buffer_size > 0);
    assert(default_limits.cgroup_monitors_count > 0);
    assert(default_limits.systemd_buffer_size > 0);
}

test "RuntimeLimits: validate accepts valid limits" {
    const valid = RuntimeLimits{
        .service_instances_count = 4,
        .proxy_connections_max = 256,
        .proxy_buffer_size = 4 * types.KIB,
        .cgroup_monitors_count = 4,
        .systemd_buffer_size = 4 * types.KIB,
    };

    try valid.validate();
}

test "RuntimeLimits: validate rejects excessive limits" {
    const invalid = RuntimeLimits{
        .service_instances_count = 255, // Exceeds max_service_instances
        .proxy_connections_max = 256,
        .proxy_buffer_size = 4 * types.KIB,
        .cgroup_monitors_count = 4,
        .systemd_buffer_size = 4 * types.KIB,
    };

    try std.testing.expectError(error.LimitExceeded, invalid.validate());
}

test "RuntimeLimits: calculate_memory_usage is reasonable" {
    const limits = default_limits;
    const memory = limits.calculate_memory_usage();

    // Should be at least the buffer pool size
    const min_expected = limits.proxy_buffer_size * limits.proxy_connections_max;
    try std.testing.expect(memory >= min_expected);

    // Should be less than 10 MiB for default config (sanity check)
    try std.testing.expect(memory < 10 * types.MIB);
}
