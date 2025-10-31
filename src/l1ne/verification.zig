//! Verification Framework for L1NE Simulation Testing
//!
//! Provides invariant checking and violation reporting.
//!
//! Design principles (TigerStyle):
//!   - Minimal: Only essential checks
//!   - Bounded: Max 64 violations tracked
//!   - No allocations: Fixed-size structures
//!   - Explicit: All invariants stated clearly
//!
//! Usage:
//!   var verifier = Verifier.init();
//!   verifier.check_service_count(&simulator);
//!   if (verifier.has_violations()) {
//!       // Handle violations
//!   }

const std = @import("std");
const assert = std.debug.assert;
const simulator_mod = @import("simulator.zig");
const service_registry = @import("service_registry.zig");

/// Maximum violations to track (TigerStyle bound)
pub const max_violations: u32 = 64;

/// Violation type
pub const ViolationType = enum(u8) {
    service_count_mismatch = 1,
    transaction_incomplete = 2,
    registry_state_invalid = 3,
    event_order_violation = 4,
};

/// Violation record
pub const Violation = struct {
    violation_type: ViolationType,
    timestamp_us: u64,
    details: [128]u8,
    details_len: u32,

    /// Create violation
    ///
    /// Invariants:
    ///   - Pre: timestamp_us > 0
    ///   - Pre: msg.len <= 128
    ///   - Post: all fields initialized
    pub fn init(
        violation_type: ViolationType,
        timestamp_us: u64,
        msg: []const u8,
    ) Violation {
        assert(timestamp_us > 0); // Timestamp must be valid
        assert(msg.len <= 128); // Message must fit

        var details: [128]u8 = [_]u8{0} ** 128;
        const len = @min(msg.len, 128);
        @memcpy(details[0..len], msg[0..len]);

        return Violation{
            .violation_type = violation_type,
            .timestamp_us = timestamp_us,
            .details = details,
            .details_len = @intCast(len),
        };
    }

    /// Get violation message
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: returns slice of details
    pub fn message(self: *const Violation) []const u8 {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(self.details_len <= 128); // Length must be valid

        return self.details[0..self.details_len];
    }
};

/// Verifier
///
/// Design:
///   - Tracks violations in bounded array
///   - Provides check functions for common invariants
///   - Minimal state tracking
pub const Verifier = struct {
    violations: [max_violations]Violation,
    violation_count: u32,

    /// Initialize verifier
    ///
    /// Invariants:
    ///   - Post: violation_count is 0
    pub fn init() Verifier {
        return Verifier{
            .violations = undefined,
            .violation_count = 0,
        };
    }

    /// Record violation
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: timestamp_us > 0
    ///   - Pre: msg.len > 0
    ///   - Post: violation_count incremented if space available
    pub fn record_violation(
        self: *Verifier,
        violation_type: ViolationType,
        timestamp_us: u64,
        msg: []const u8,
    ) void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(timestamp_us > 0); // Timestamp must be valid
        assert(msg.len > 0); // Message must not be empty

        if (self.violation_count >= max_violations) {
            return; // Silently drop if full
        }

        const old_count = self.violation_count;

        self.violations[self.violation_count] = Violation.init(
            violation_type,
            timestamp_us,
            msg,
        );
        self.violation_count += 1;

        assert(self.violation_count == old_count + 1); // Count incremented
        assert(self.violation_count <= max_violations); // Within bounds
    }

    /// Check if has violations
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: returns true if violations > 0
    pub fn has_violations(self: *const Verifier) bool {
        assert(@intFromPtr(self) != 0); // Self must be valid

        return self.violation_count > 0;
    }

    /// Clear all violations
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: violation_count is 0
    pub fn clear(self: *Verifier) void {
        assert(@intFromPtr(self) != 0); // Self must be valid

        self.violation_count = 0;

        assert(self.violation_count == 0); // Count must be zero
    }

    /// Check service count consistency
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: sim is valid pointer
    ///   - Post: violation recorded if mismatch
    pub fn check_service_count(
        self: *Verifier,
        sim: *const simulator_mod.Simulator,
    ) void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(@intFromPtr(sim) != 0); // Simulator must be valid

        const started = sim.state.services_started;
        const stopped = sim.state.services_stopped;

        if (started < stopped) {
            const timestamp = sim.clock.now().to_us();
            self.record_violation(
                .service_count_mismatch,
                timestamp,
                "services_stopped > services_started",
            );
        }
    }

    /// Check transaction consistency
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: sim is valid pointer
    ///   - Post: violation recorded if incomplete
    pub fn check_transaction_state(
        self: *Verifier,
        sim: *const simulator_mod.Simulator,
    ) void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(@intFromPtr(sim) != 0); // Simulator must be valid

        if (sim.in_transaction and sim.pending_count > 0) {
            const timestamp = sim.clock.now().to_us();
            self.record_violation(
                .transaction_incomplete,
                timestamp,
                "transaction has pending events without commit",
            );
        }
    }
};

// Inline tests
const testing = std.testing;

test "Verifier: init with zero violations" {
    const verifier = Verifier.init();

    try testing.expectEqual(@as(u32, 0), verifier.violation_count);
    try testing.expect(!verifier.has_violations());
}

test "Verifier: record and retrieve violation" {
    var verifier = Verifier.init();

    verifier.record_violation(
        .service_count_mismatch,
        1_000_000,
        "test violation",
    );

    try testing.expect(verifier.has_violations());
    try testing.expectEqual(@as(u32, 1), verifier.violation_count);

    const violation = &verifier.violations[0];
    try testing.expectEqual(ViolationType.service_count_mismatch, violation.violation_type);
    try testing.expectEqual(@as(u64, 1_000_000), violation.timestamp_us);
    try testing.expectEqualStrings("test violation", violation.message());
}

test "Verifier: clear removes all violations" {
    var verifier = Verifier.init();

    verifier.record_violation(.service_count_mismatch, 1_000_000, "first");
    verifier.record_violation(.transaction_incomplete, 2_000_000, "second");

    try testing.expectEqual(@as(u32, 2), verifier.violation_count);

    verifier.clear();

    try testing.expectEqual(@as(u32, 0), verifier.violation_count);
    try testing.expect(!verifier.has_violations());
}

test "Verifier: bounded violation tracking" {
    var verifier = Verifier.init();

    // Fill to max
    var i: u32 = 0;
    while (i < max_violations) : (i += 1) {
        verifier.record_violation(.service_count_mismatch, 1_000_000 + i, "violation");
    }

    try testing.expectEqual(max_violations, verifier.violation_count);

    // Attempt to exceed max (should silently drop)
    verifier.record_violation(.service_count_mismatch, 2_000_000, "overflow");

    try testing.expectEqual(max_violations, verifier.violation_count);
}
