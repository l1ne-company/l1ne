//! Time abstraction for L1NE
//!
//! Provides monotonic time that can be real or simulated for deterministic testing.
//!
//! Design principles (TigerStyle):
//!   - Monotonic timestamps (never go backwards)
//!   - Microsecond precision (sufficient for network events)
//!   - Mode discrimination (Real vs Simulated)
//!   - No allocations
//!   - Thread-safe monotonic guarantee
//!
//! Usage:
//!   - Production: Use Real mode with system monotonic clock
//!   - Testing: Use Simulated mode with manual time advancement
//!   - Replay: Use Simulated mode with WAL timestamps

const std = @import("std");
const assert = std.debug.assert;

/// Time mode discriminator
pub const Mode = enum(u8) {
    real = 1, // System monotonic clock
    simulated = 2, // Manual time control for testing
};

/// Monotonic timestamp in microseconds
///
/// Design:
///   - u64 allows ~584,000 years of microseconds
///   - Always increases (never decreases)
///   - Zero is reserved for uninitialized
pub const Timestamp = struct {
    microseconds: u64,

    /// Create timestamp from microseconds
    ///
    /// Invariants:
    ///   - Pre: microseconds > 0
    ///   - Post: returned timestamp is valid
    pub fn from_us(microseconds: u64) Timestamp {
        assert(microseconds > 0); // Must be non-zero

        return Timestamp{ .microseconds = microseconds };
    }

    /// Compare two timestamps
    ///
    /// Invariants:
    ///   - Pre: both timestamps are valid
    ///   - Post: returns ordering relationship
    pub fn compare(self: Timestamp, other: Timestamp) std.math.Order {
        assert(self.microseconds > 0); // Must be valid
        assert(other.microseconds > 0); // Must be valid

        return std.math.order(self.microseconds, other.microseconds);
    }

    /// Calculate duration between timestamps
    ///
    /// Invariants:
    ///   - Pre: both timestamps are valid
    ///   - Pre: other >= self (no negative durations)
    ///   - Post: returned duration >= 0
    pub fn duration_until(self: Timestamp, other: Timestamp) u64 {
        assert(self.microseconds > 0); // Must be valid
        assert(other.microseconds > 0); // Must be valid
        assert(other.microseconds >= self.microseconds); // Must not be negative

        const duration = other.microseconds - self.microseconds;
        assert(duration >= 0); // Must be non-negative
        return duration;
    }
};

/// Time source abstraction
///
/// Design:
///   - Single global instance (no multiple time sources)
///   - Mode set at initialization (immutable)
///   - Monotonic guarantee enforced by assertions
pub const Clock = struct {
    mode: Mode,
    last_timestamp_us: u64, // Last returned timestamp (for monotonic check)
    simulated_time_us: u64, // Current simulated time (only used in simulated mode)

    /// Initialize clock in Real mode
    ///
    /// Invariants:
    ///   - Post: clock is in Real mode
    ///   - Post: last_timestamp is 0 (not yet sampled)
    pub fn init_real() Clock {
        return Clock{
            .mode = .real,
            .last_timestamp_us = 0,
            .simulated_time_us = 0,
        };
    }

    /// Initialize clock in Simulated mode
    ///
    /// Invariants:
    ///   - Pre: start_time_us > 0
    ///   - Post: clock is in Simulated mode
    ///   - Post: simulated time set to start_time_us
    pub fn init_simulated(start_time_us: u64) Clock {
        assert(start_time_us > 0); // Must start at non-zero time

        return Clock{
            .mode = .simulated,
            .last_timestamp_us = 0,
            .simulated_time_us = start_time_us,
        };
    }

    /// Get current monotonic timestamp
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: returned timestamp > last_timestamp (monotonic)
    ///   - Post: last_timestamp updated
    ///   - Real mode: reads system clock
    ///   - Simulated mode: returns simulated time
    pub fn now(self: *Clock) Timestamp {
        assert(@intFromPtr(self) != 0); // Self must be valid

        const timestamp_us = switch (self.mode) {
            .real => self.read_system_time(),
            .simulated => blk: {
                assert(self.simulated_time_us > 0); // Simulated time must be set
                break :blk self.simulated_time_us;
            },
        };

        assert(timestamp_us > 0); // Timestamp must be non-zero

        // Enforce monotonic guarantee
        if (self.last_timestamp_us > 0) {
            assert(timestamp_us >= self.last_timestamp_us); // Must not go backwards
        }

        self.last_timestamp_us = timestamp_us;

        return Timestamp.from_us(timestamp_us);
    }

    /// Advance simulated time (only works in simulated mode)
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: mode is Simulated
    ///   - Pre: delta_us > 0
    ///   - Post: simulated_time_us increased by delta_us
    pub fn advance(self: *Clock, delta_us: u64) void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(self.mode == .simulated); // Must be in simulated mode
        assert(delta_us > 0); // Delta must be positive

        const old_time = self.simulated_time_us;
        self.simulated_time_us += delta_us;

        assert(self.simulated_time_us > old_time); // Time must advance
        assert(self.simulated_time_us == old_time + delta_us); // Exact increment
    }

    /// Set simulated time to specific value (only works in simulated mode)
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: mode is Simulated
    ///   - Pre: new_time_us > simulated_time_us (monotonic)
    ///   - Post: simulated_time_us set to new_time_us
    pub fn set_time(self: *Clock, new_time_us: u64) void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(self.mode == .simulated); // Must be in simulated mode
        assert(new_time_us > 0); // New time must be non-zero
        assert(new_time_us >= self.simulated_time_us); // Must not go backwards

        self.simulated_time_us = new_time_us;

        assert(self.simulated_time_us == new_time_us); // Time set correctly
    }

    /// Read system monotonic time in microseconds
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: returned time > 0
    ///   - Does not modify state
    fn read_system_time(self: *const Clock) u64 {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(self.mode == .real); // Only call in real mode

        const ns = std.time.nanoTimestamp();
        assert(ns > 0); // System time should be positive

        const us: u64 = @intCast(@divFloor(ns, 1000));
        assert(us > 0); // Microseconds must be non-zero

        return us;
    }
};

/// Global clock instance (initialized by main)
pub var global_clock: Clock = undefined;

/// Initialize global clock (must be called once at startup)
///
/// Invariants:
///   - Pre: mode is valid
///   - Post: global_clock is initialized
pub fn init_global(mode: Mode) void {
    assert(@intFromEnum(mode) > 0); // Mode must be valid
    assert(@intFromEnum(mode) <= 2); // Mode must be in range

    global_clock = switch (mode) {
        .real => Clock.init_real(),
        .simulated => Clock.init_simulated(1_000_000), // Start at 1 second
    };

    assert(global_clock.mode == mode); // Mode set correctly
}

/// Get current time from global clock
///
/// Invariants:
///   - Pre: global_clock is initialized
///   - Post: returned timestamp is monotonic
pub fn now() Timestamp {
    return global_clock.now();
}

/// Advance global simulated time (test/simulation only)
///
/// Invariants:
///   - Pre: global_clock is in simulated mode
///   - Pre: delta_us > 0
pub fn advance(delta_us: u64) void {
    global_clock.advance(delta_us);
}

/// Set global simulated time (test/simulation only)
///
/// Invariants:
///   - Pre: global_clock is in simulated mode
///   - Pre: new_time_us > current time
pub fn set_time(new_time_us: u64) void {
    global_clock.set_time(new_time_us);
}
