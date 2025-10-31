//! Metrics Collection for L1NE Simulation Testing
//!
//! Provides minimal observability for simulation runs.
//!
//! Design principles (TigerStyle):
//!   - Minimal: Only essential metrics
//!   - Bounded: Fixed-size storage
//!   - No allocations: Stack-based structures
//!   - Simple aggregations: min/max/avg only
//!
//! Usage:
//!   var metrics = Metrics.init();
//!   metrics.record_event();
//!   metrics.record_latency_us(1234);
//!   const summary = metrics.summarize();

const std = @import("std");
const assert = std.debug.assert;

/// Maximum latency samples (TigerStyle bound)
pub const max_latency_samples: u32 = 1024;

/// Metrics collector
///
/// Design:
///   - Simple counters for events
///   - Bounded latency tracking
///   - Basic aggregations
pub const Metrics = struct {
    events_total: u64,
    transactions_committed: u64,
    transactions_aborted: u64,
    faults_injected: u64,
    services_started: u64,
    services_stopped: u64,
    latency_samples: [max_latency_samples]u64,
    latency_count: u32,

    /// Initialize metrics
    ///
    /// Invariants:
    ///   - Post: all counters are 0
    pub fn init() Metrics {
        return Metrics{
            .events_total = 0,
            .transactions_committed = 0,
            .transactions_aborted = 0,
            .faults_injected = 0,
            .services_started = 0,
            .services_stopped = 0,
            .latency_samples = undefined,
            .latency_count = 0,
        };
    }

    /// Record event
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: events_total incremented
    pub fn record_event(self: *Metrics) void {
        assert(@intFromPtr(self) != 0); // Self must be valid

        const old_count = self.events_total;
        self.events_total += 1;

        assert(self.events_total == old_count + 1); // Count incremented
    }

    /// Record transaction commit
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: transactions_committed incremented
    pub fn record_commit(self: *Metrics) void {
        assert(@intFromPtr(self) != 0); // Self must be valid

        const old_count = self.transactions_committed;
        self.transactions_committed += 1;

        assert(self.transactions_committed == old_count + 1); // Count incremented
    }

    /// Record transaction abort
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: transactions_aborted incremented
    pub fn record_abort(self: *Metrics) void {
        assert(@intFromPtr(self) != 0); // Self must be valid

        const old_count = self.transactions_aborted;
        self.transactions_aborted += 1;

        assert(self.transactions_aborted == old_count + 1); // Count incremented
    }

    /// Record fault injection
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: faults_injected incremented
    pub fn record_fault(self: *Metrics) void {
        assert(@intFromPtr(self) != 0); // Self must be valid

        const old_count = self.faults_injected;
        self.faults_injected += 1;

        assert(self.faults_injected == old_count + 1); // Count incremented
    }

    /// Record service start
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: services_started incremented
    pub fn record_service_start(self: *Metrics) void {
        assert(@intFromPtr(self) != 0); // Self must be valid

        const old_count = self.services_started;
        self.services_started += 1;

        assert(self.services_started == old_count + 1); // Count incremented
    }

    /// Record service stop
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: services_stopped incremented
    pub fn record_service_stop(self: *Metrics) void {
        assert(@intFromPtr(self) != 0); // Self must be valid

        const old_count = self.services_stopped;
        self.services_stopped += 1;

        assert(self.services_stopped == old_count + 1); // Count incremented
    }

    /// Record latency sample
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: latency_us > 0
    ///   - Post: latency_count incremented if space available
    pub fn record_latency_us(self: *Metrics, latency_us: u64) void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(latency_us > 0); // Latency must be positive

        if (self.latency_count >= max_latency_samples) {
            return; // Silently drop if full
        }

        const old_count = self.latency_count;

        self.latency_samples[self.latency_count] = latency_us;
        self.latency_count += 1;

        assert(self.latency_count == old_count + 1); // Count incremented
        assert(self.latency_count <= max_latency_samples); // Within bounds
    }

    /// Get latency statistics
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: returns min/max/avg if samples exist
    pub fn latency_stats(self: *const Metrics) LatencyStats {
        assert(@intFromPtr(self) != 0); // Self must be valid

        if (self.latency_count == 0) {
            return LatencyStats{
                .min_us = 0,
                .max_us = 0,
                .avg_us = 0,
            };
        }

        var min_us: u64 = std.math.maxInt(u64);
        var max_us: u64 = 0;
        var sum_us: u64 = 0;

        var i: u32 = 0;
        while (i < self.latency_count) : (i += 1) {
            const sample = self.latency_samples[i];
            min_us = @min(min_us, sample);
            max_us = @max(max_us, sample);
            sum_us += sample;
        }

        const avg_us = sum_us / self.latency_count;

        assert(min_us <= avg_us); // Min must be <= avg
        assert(avg_us <= max_us); // Avg must be <= max

        return LatencyStats{
            .min_us = min_us,
            .max_us = max_us,
            .avg_us = avg_us,
        };
    }

    /// Reset all metrics
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: all counters are 0
    pub fn reset(self: *Metrics) void {
        assert(@intFromPtr(self) != 0); // Self must be valid

        self.events_total = 0;
        self.transactions_committed = 0;
        self.transactions_aborted = 0;
        self.faults_injected = 0;
        self.services_started = 0;
        self.services_stopped = 0;
        self.latency_count = 0;

        assert(self.events_total == 0); // Must be zero
        assert(self.latency_count == 0); // Must be zero
    }
};

/// Latency statistics
pub const LatencyStats = struct {
    min_us: u64,
    max_us: u64,
    avg_us: u64,
};

// Inline tests
const testing = std.testing;

test "Metrics: init with zero counters" {
    const metrics = Metrics.init();

    try testing.expectEqual(@as(u64, 0), metrics.events_total);
    try testing.expectEqual(@as(u64, 0), metrics.transactions_committed);
    try testing.expectEqual(@as(u64, 0), metrics.faults_injected);
    try testing.expectEqual(@as(u32, 0), metrics.latency_count);
}

test "Metrics: record events" {
    var metrics = Metrics.init();

    metrics.record_event();
    metrics.record_event();
    metrics.record_event();

    try testing.expectEqual(@as(u64, 3), metrics.events_total);
}

test "Metrics: record transactions" {
    var metrics = Metrics.init();

    metrics.record_commit();
    metrics.record_commit();
    metrics.record_abort();

    try testing.expectEqual(@as(u64, 2), metrics.transactions_committed);
    try testing.expectEqual(@as(u64, 1), metrics.transactions_aborted);
}

test "Metrics: record services" {
    var metrics = Metrics.init();

    metrics.record_service_start();
    metrics.record_service_start();
    metrics.record_service_stop();

    try testing.expectEqual(@as(u64, 2), metrics.services_started);
    try testing.expectEqual(@as(u64, 1), metrics.services_stopped);
}

test "Metrics: latency stats with samples" {
    var metrics = Metrics.init();

    metrics.record_latency_us(1000);
    metrics.record_latency_us(2000);
    metrics.record_latency_us(3000);

    const stats = metrics.latency_stats();

    try testing.expectEqual(@as(u64, 1000), stats.min_us);
    try testing.expectEqual(@as(u64, 3000), stats.max_us);
    try testing.expectEqual(@as(u64, 2000), stats.avg_us);
}

test "Metrics: latency stats with no samples" {
    const metrics = Metrics.init();
    const stats = metrics.latency_stats();

    try testing.expectEqual(@as(u64, 0), stats.min_us);
    try testing.expectEqual(@as(u64, 0), stats.max_us);
    try testing.expectEqual(@as(u64, 0), stats.avg_us);
}

test "Metrics: reset clears all counters" {
    var metrics = Metrics.init();

    metrics.record_event();
    metrics.record_commit();
    metrics.record_latency_us(1000);

    try testing.expect(metrics.events_total > 0);
    try testing.expect(metrics.transactions_committed > 0);
    try testing.expect(metrics.latency_count > 0);

    metrics.reset();

    try testing.expectEqual(@as(u64, 0), metrics.events_total);
    try testing.expectEqual(@as(u64, 0), metrics.transactions_committed);
    try testing.expectEqual(@as(u32, 0), metrics.latency_count);
}

test "Metrics: bounded latency tracking" {
    var metrics = Metrics.init();

    // Fill to max
    var i: u32 = 0;
    while (i < max_latency_samples) : (i += 1) {
        metrics.record_latency_us(1000 + i);
    }

    try testing.expectEqual(max_latency_samples, metrics.latency_count);

    // Attempt to exceed max (should silently drop)
    metrics.record_latency_us(99999);

    try testing.expectEqual(max_latency_samples, metrics.latency_count);
}
