//! Fault Injector for Chaos Testing in L1NE
//!
//! Provides deterministic fault injection for testing system resilience.
//!
//! Design principles (TigerStyle):
//!   - Deterministic: Uses PRNG for reproducible chaos
//!   - Bounded: Max 64 pending faults
//!   - No allocations: Fixed-size structures
//!   - Explicit: All faults explicitly configured
//!
//! Fault types:
//!   - ServiceCrash: Service instance terminates unexpectedly
//!   - Delay: Operation completes after delay
//!   - ResourceExhaustion: Memory/CPU limits exceeded
//!   - ConnectionFailure: Network connection fails
//!
//! Usage:
//!   var prng = PRNG.init(12345);
//!   var injector = FaultInjector.init(&prng);
//!   injector.configure(.{ .crash_probability = 0.05 });
//!   if (injector.should_inject_crash(service_id, timestamp)) {
//!       // Handle crash
//!   }

const std = @import("std");
const assert = std.debug.assert;
const prng_mod = @import("prng.zig");

/// Maximum pending faults (TigerStyle bound)
pub const max_pending_faults: u32 = 64;

/// Fault types
pub const FaultType = enum(u8) {
    service_crash = 1,
    delay = 2,
    resource_exhaustion = 3,
    connection_failure = 4,
};

/// Fault injection configuration
pub const FaultConfig = struct {
    /// Probability of service crash per operation [0.0, 1.0]
    crash_probability: f64 = 0.0,

    /// Probability of delay per operation [0.0, 1.0]
    delay_probability: f64 = 0.0,

    /// Probability of resource exhaustion [0.0, 1.0]
    resource_exhaustion_probability: f64 = 0.0,

    /// Probability of connection failure [0.0, 1.0]
    connection_failure_probability: f64 = 0.0,

    /// Delay duration range (microseconds)
    delay_min_us: u64 = 1000,    // 1ms
    delay_max_us: u64 = 100_000, // 100ms
};

/// Pending fault entry
pub const PendingFault = struct {
    fault_type: FaultType,
    target_service_id: u32,
    scheduled_time_us: u64,
    parameter: u64, // Fault-specific parameter (e.g., delay duration)

    /// Create a pending fault
    ///
    /// Invariants:
    ///   - Pre: target_service_id > 0
    ///   - Pre: scheduled_time_us > 0
    ///   - Post: all fields initialized
    pub fn init(
        fault_type: FaultType,
        target_service_id: u32,
        scheduled_time_us: u64,
        parameter: u64,
    ) PendingFault {
        assert(target_service_id > 0); // Service ID must be valid
        assert(scheduled_time_us > 0); // Time must be valid

        return PendingFault{
            .fault_type = fault_type,
            .target_service_id = target_service_id,
            .scheduled_time_us = scheduled_time_us,
            .parameter = parameter,
        };
    }
};

/// Fault Injector
///
/// Design:
///   - Uses PRNG for deterministic randomness
///   - Bounded array of pending faults
///   - Configurable fault probabilities
pub const FaultInjector = struct {
    config: FaultConfig,
    pending_faults: [max_pending_faults]PendingFault,
    pending_count: u32,
    total_crashes_injected: u64,
    total_delays_injected: u64,
    total_resource_exhaustions_injected: u64,
    total_connection_failures_injected: u64,

    /// Initialize fault injector
    ///
    /// Invariants:
    ///   - Post: pending_count is 0
    ///   - Post: all counters are 0
    pub fn init() FaultInjector {
        return FaultInjector{
            .config = FaultConfig{},
            .pending_faults = undefined,
            .pending_count = 0,
            .total_crashes_injected = 0,
            .total_delays_injected = 0,
            .total_resource_exhaustions_injected = 0,
            .total_connection_failures_injected = 0,
        };
    }

    /// Configure fault injection probabilities
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: all probabilities in [0.0, 1.0]
    ///   - Post: config updated
    pub fn configure(self: *FaultInjector, config: FaultConfig) void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(config.crash_probability >= 0.0 and config.crash_probability <= 1.0);
        assert(config.delay_probability >= 0.0 and config.delay_probability <= 1.0);
        assert(config.resource_exhaustion_probability >= 0.0 and
               config.resource_exhaustion_probability <= 1.0);
        assert(config.connection_failure_probability >= 0.0 and
               config.connection_failure_probability <= 1.0);
        assert(config.delay_min_us <= config.delay_max_us);

        self.config = config;
    }

    /// Check if crash should be injected for service
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: prng is valid pointer
    ///   - Pre: service_id > 0
    ///   - Pre: timestamp_us > 0
    ///   - Post: returns true with configured probability
    pub fn should_inject_crash(
        self: *FaultInjector,
        prng: *prng_mod.PRNG,
        service_id: u32,
        timestamp_us: u64,
    ) bool {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(@intFromPtr(prng) != 0); // PRNG must be valid
        assert(service_id > 0); // Service ID must be valid
        assert(timestamp_us > 0); // Timestamp must be valid

        if (self.config.crash_probability <= 0.0) return false;

        const should_crash = prng.next_bool(self.config.crash_probability);

        if (should_crash) {
            self.total_crashes_injected += 1;
        }

        return should_crash;
    }

    /// Check if delay should be injected
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: prng is valid pointer
    ///   - Pre: timestamp_us > 0
    ///   - Post: returns delay duration in microseconds, or 0 if no delay
    pub fn should_inject_delay(
        self: *FaultInjector,
        prng: *prng_mod.PRNG,
        timestamp_us: u64,
    ) u64 {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(@intFromPtr(prng) != 0); // PRNG must be valid
        assert(timestamp_us > 0); // Timestamp must be valid

        if (self.config.delay_probability <= 0.0) return 0;

        const should_delay = prng.next_bool(self.config.delay_probability);

        if (!should_delay) return 0;

        // Generate random delay duration
        const min: u32 = @intCast(@min(self.config.delay_min_us, std.math.maxInt(u32)));
        const max: u32 = @intCast(@min(self.config.delay_max_us, std.math.maxInt(u32)));
        const delay_us = prng.next_range(min, max);

        self.total_delays_injected += 1;

        assert(delay_us >= self.config.delay_min_us); // Must be >= min
        assert(delay_us <= self.config.delay_max_us); // Must be <= max
        return delay_us;
    }

    /// Check if resource exhaustion should be injected
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: prng is valid pointer
    ///   - Pre: timestamp_us > 0
    ///   - Post: returns true with configured probability
    pub fn should_inject_resource_exhaustion(
        self: *FaultInjector,
        prng: *prng_mod.PRNG,
        timestamp_us: u64,
    ) bool {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(@intFromPtr(prng) != 0); // PRNG must be valid
        assert(timestamp_us > 0); // Timestamp must be valid

        if (self.config.resource_exhaustion_probability <= 0.0) return false;

        const should_exhaust = prng.next_bool(
            self.config.resource_exhaustion_probability
        );

        if (should_exhaust) {
            self.total_resource_exhaustions_injected += 1;
        }

        return should_exhaust;
    }

    /// Check if connection failure should be injected
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: prng is valid pointer
    ///   - Pre: connection_id > 0
    ///   - Pre: timestamp_us > 0
    ///   - Post: returns true with configured probability
    pub fn should_inject_connection_failure(
        self: *FaultInjector,
        prng: *prng_mod.PRNG,
        connection_id: u64,
        timestamp_us: u64,
    ) bool {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(@intFromPtr(prng) != 0); // PRNG must be valid
        assert(connection_id > 0); // Connection ID must be valid
        assert(timestamp_us > 0); // Timestamp must be valid

        if (self.config.connection_failure_probability <= 0.0) return false;

        const should_fail = prng.next_bool(
            self.config.connection_failure_probability
        );

        if (should_fail) {
            self.total_connection_failures_injected += 1;
        }

        return should_fail;
    }

    /// Schedule a fault for future injection
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: pending_count < max_pending_faults
    ///   - Pre: service_id > 0
    ///   - Pre: scheduled_time_us > 0
    ///   - Post: pending_count incremented
    pub fn schedule_fault(
        self: *FaultInjector,
        fault_type: FaultType,
        service_id: u32,
        scheduled_time_us: u64,
        parameter: u64,
    ) !void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(service_id > 0); // Service ID must be valid
        assert(scheduled_time_us > 0); // Time must be valid

        if (self.pending_count >= max_pending_faults) {
            return error.TooManyPendingFaults;
        }

        const old_count = self.pending_count;

        self.pending_faults[self.pending_count] = PendingFault.init(
            fault_type,
            service_id,
            scheduled_time_us,
            parameter,
        );
        self.pending_count += 1;

        assert(self.pending_count == old_count + 1); // Count incremented
        assert(self.pending_count <= max_pending_faults); // Within bounds
    }

    /// Get pending faults due at or before timestamp
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: timestamp_us > 0
    ///   - Post: returned slice contains faults <= timestamp
    pub fn get_due_faults(
        self: *const FaultInjector,
        timestamp_us: u64,
        out_buffer: []PendingFault,
    ) u32 {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(timestamp_us > 0); // Timestamp must be valid
        assert(out_buffer.len >= max_pending_faults); // Buffer must be large enough

        var count: u32 = 0;

        var i: u32 = 0;
        while (i < self.pending_count) : (i += 1) {
            const fault = self.pending_faults[i];
            if (fault.scheduled_time_us <= timestamp_us) {
                out_buffer[count] = fault;
                count += 1;
            }
        }

        assert(count <= self.pending_count); // Can't exceed total
        return count;
    }

    /// Clear all pending faults
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: pending_count is 0
    pub fn clear_pending(self: *FaultInjector) void {
        assert(@intFromPtr(self) != 0); // Self must be valid

        self.pending_count = 0;

        assert(self.pending_count == 0); // Count must be zero
    }

    /// Get total faults injected
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: returns sum of all fault counters
    pub fn total_faults_injected(self: *const FaultInjector) u64 {
        assert(@intFromPtr(self) != 0); // Self must be valid

        return self.total_crashes_injected +
               self.total_delays_injected +
               self.total_resource_exhaustions_injected +
               self.total_connection_failures_injected;
    }
};

// Inline tests
const testing = std.testing;

test "FaultInjector: init with zero faults" {
    const injector = FaultInjector.init();

    try testing.expectEqual(@as(u32, 0), injector.pending_count);
    try testing.expectEqual(@as(u64, 0), injector.total_faults_injected());
}

test "FaultInjector: crash injection with 0.0 probability never crashes" {
    var prng = prng_mod.PRNG.init(123);
    var injector = FaultInjector.init();
    injector.configure(.{ .crash_probability = 0.0 });

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const should_crash = injector.should_inject_crash(&prng, 1, 1_000_000);
        try testing.expect(!should_crash);
    }

    try testing.expectEqual(@as(u64, 0), injector.total_crashes_injected);
}

test "FaultInjector: delay injection returns value in range" {
    var prng = prng_mod.PRNG.init(456);
    var injector = FaultInjector.init();
    injector.configure(.{
        .delay_probability = 1.0,
        .delay_min_us = 1000,
        .delay_max_us = 5000,
    });

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const delay = injector.should_inject_delay(&prng, 1_000_000);
        if (delay > 0) {
            try testing.expect(delay >= 1000);
            try testing.expect(delay <= 5000);
        }
    }

    try testing.expect(injector.total_delays_injected > 0);
}

test "FaultInjector: schedule and retrieve pending faults" {
    var injector = FaultInjector.init();

    // Schedule 3 faults
    try injector.schedule_fault(.service_crash, 1, 1_000_000, 0);
    try injector.schedule_fault(.delay, 2, 2_000_000, 1000);
    try injector.schedule_fault(.service_crash, 3, 3_000_000, 0);

    try testing.expectEqual(@as(u32, 3), injector.pending_count);

    // Get faults due at 2_000_000
    var buffer: [max_pending_faults]PendingFault = undefined;
    const due_count = injector.get_due_faults(2_000_000, &buffer);

    try testing.expectEqual(@as(u32, 2), due_count); // First two faults
}

test "FaultInjector: clear pending removes all faults" {
    var injector = FaultInjector.init();

    try injector.schedule_fault(.service_crash, 1, 1_000_000, 0);
    try injector.schedule_fault(.delay, 2, 2_000_000, 1000);

    try testing.expectEqual(@as(u32, 2), injector.pending_count);

    injector.clear_pending();

    try testing.expectEqual(@as(u32, 0), injector.pending_count);
}

test "FaultInjector: deterministic injection with same seed" {
    var prng1 = prng_mod.PRNG.init(42);
    var prng2 = prng_mod.PRNG.init(42);

    var inj1 = FaultInjector.init();
    var inj2 = FaultInjector.init();

    inj1.configure(.{ .crash_probability = 0.5 });
    inj2.configure(.{ .crash_probability = 0.5 });

    // Same seed produces same results
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const crash1 = inj1.should_inject_crash(&prng1, 1, 1_000_000 + i);
        const crash2 = inj2.should_inject_crash(&prng2, 1, 1_000_000 + i);
        try testing.expectEqual(crash1, crash2);
    }
}

test "FaultInjector: bounded pending faults" {
    var injector = FaultInjector.init();

    // Fill to max
    var i: u32 = 0;
    while (i < max_pending_faults) : (i += 1) {
        try injector.schedule_fault(.service_crash, i + 1, 1_000_000 + i, 0);
    }

    try testing.expectEqual(max_pending_faults, injector.pending_count);

    // Attempt to exceed max
    const result = injector.schedule_fault(.service_crash, 100, 1_000_000, 0);
    try testing.expectError(error.TooManyPendingFaults, result);
}
