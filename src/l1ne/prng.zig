//! Deterministic Pseudo-Random Number Generator for L1NE
//!
//! Uses PCG32 algorithm for fast, high-quality deterministic randomness.
//!
//! Design principles (TigerStyle):
//!   - Deterministic: Same seed produces identical sequence
//!   - No allocations: Fixed-size state
//!   - Fast: PCG32 is one of the fastest high-quality PRNGs
//!   - Bounded: Fixed state size
//!
//! PCG32 (Permuted Congruential Generator):
//!   - 64-bit internal state
//!   - 32-bit output
//!   - Period: 2^64
//!   - Passes statistical tests (TestU01, PractRand)
//!
//! Usage:
//!   var rng = PRNG.init(12345);
//!   const value = rng.next_u32();
//!   const in_range = rng.next_range(0, 100);
//!   const coin_flip = rng.next_bool(0.5);

const std = @import("std");
const assert = std.debug.assert;

/// PCG32 multiplier constant
const PCG_MULTIPLIER: u64 = 6364136223846793005;

/// PCG32 default increment (must be odd)
const PCG_INCREMENT: u64 = 1442695040888963407;

/// Pseudo-Random Number Generator (PCG32)
///
/// Design:
///   - 64-bit internal state
///   - 32-bit output
///   - Deterministic sequence from seed
pub const PRNG = struct {
    state: u64,
    increment: u64,

    /// Initialize PRNG with seed
    ///
    /// Invariants:
    ///   - Post: state is non-zero
    ///   - Post: increment is odd (required by PCG)
    ///   - Post: same seed produces same sequence
    pub fn init(seed: u64) PRNG {
        var rng = PRNG{
            .state = 0,
            .increment = PCG_INCREMENT,
        };

        // PCG initialization sequence
        rng.state = 0;
        _ = rng.next_u32();
        rng.state +%= seed;
        _ = rng.next_u32();

        assert(rng.increment & 1 == 1); // Increment must be odd
        assert(rng.state != 0); // State should be initialized
        return rng;
    }

    /// Generate next 32-bit random number
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: state advanced
    ///   - Post: returns value in [0, 2^32)
    pub fn next_u32(self: *PRNG) u32 {
        assert(@intFromPtr(self) != 0); // Self must be valid

        const old_state = self.state;

        // Advance state (LCG step)
        self.state = old_state *% PCG_MULTIPLIER +% self.increment;

        // Output permutation (XSH-RR)
        const xorshifted: u32 = @truncate(((old_state >> 18) ^ old_state) >> 27);
        const rot: u32 = @truncate(old_state >> 59);

        const result = (xorshifted >> @intCast(rot)) |
                      (xorshifted << @intCast((-%rot) & 31));

        assert(self.state != old_state); // State must advance
        return result;
    }

    /// Generate random u64
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: returns 64-bit value
    pub fn next_u64(self: *PRNG) u64 {
        assert(@intFromPtr(self) != 0); // Self must be valid

        const high: u64 = self.next_u32();
        const low: u64 = self.next_u32();

        const result = (high << 32) | low;
        return result;
    }

    /// Generate random number in range [min, max]
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: min <= max
    ///   - Post: result >= min
    ///   - Post: result <= max
    pub fn next_range(self: *PRNG, min: u32, max: u32) u32 {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(min <= max); // Range must be valid

        if (min == max) {
            return min;
        }

        const range = max - min + 1;
        const value = self.next_u32();
        const result = min + (value % range);

        assert(result >= min); // Must be >= min
        assert(result <= max); // Must be <= max
        return result;
    }

    /// Generate random boolean with given probability
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: probability in [0.0, 1.0]
    ///   - Post: returns true with given probability
    pub fn next_bool(self: *PRNG, probability: f64) bool {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(probability >= 0.0); // Probability must be non-negative
        assert(probability <= 1.0); // Probability must be <= 1.0

        if (probability <= 0.0) return false;
        if (probability >= 1.0) return true;

        const value = self.next_u32();
        const threshold = @as(u32, @intFromFloat(probability * @as(f64, @floatFromInt(std.math.maxInt(u32)))));

        return value < threshold;
    }

    /// Fill buffer with random bytes
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: buffer is valid slice
    ///   - Post: all bytes in buffer are randomized
    pub fn fill_bytes(self: *PRNG, buffer: []u8) void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(buffer.len > 0); // Buffer must not be empty

        var i: usize = 0;
        while (i < buffer.len) {
            const remaining = buffer.len - i;

            if (remaining >= 4) {
                // Fill 4 bytes at once
                const value = self.next_u32();
                const bytes = std.mem.asBytes(&value);
                @memcpy(buffer[i..i+4], bytes);
                i += 4;
            } else {
                // Fill remaining bytes
                const value = self.next_u32();
                const bytes = std.mem.asBytes(&value);
                @memcpy(buffer[i..], bytes[0..remaining]);
                i += remaining;
            }
        }

        assert(i == buffer.len); // All bytes filled
    }

    /// Shuffle array using Fisher-Yates algorithm
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: array is valid slice
    ///   - Post: array contains same elements in random order
    pub fn shuffle(self: *PRNG, comptime T: type, array: []T) void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(array.len <= std.math.maxInt(u32)); // Length must fit in u32

        if (array.len <= 1) return;

        var i = array.len - 1;
        while (i > 0) : (i -= 1) {
            const j = self.next_range(0, @intCast(i));
            const tmp = array[i];
            array[i] = array[j];
            array[j] = tmp;
        }
    }
};

// Inline tests
const testing = std.testing;

test "PRNG: deterministic sequence" {
    var rng1 = PRNG.init(12345);
    var rng2 = PRNG.init(12345);

    // Same seed produces same sequence
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const v1 = rng1.next_u32();
        const v2 = rng2.next_u32();
        try testing.expectEqual(v1, v2);
    }
}

test "PRNG: different seeds produce different sequences" {
    var rng1 = PRNG.init(12345);
    var rng2 = PRNG.init(67890);

    const v1 = rng1.next_u32();
    const v2 = rng2.next_u32();

    try testing.expect(v1 != v2);
}

test "PRNG: next_range respects bounds" {
    var rng = PRNG.init(42);

    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const value = rng.next_range(10, 20);
        try testing.expect(value >= 10);
        try testing.expect(value <= 20);
    }
}

test "PRNG: next_bool with 0.0 always false" {
    var rng = PRNG.init(123);

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try testing.expect(!rng.next_bool(0.0));
    }
}

test "PRNG: next_bool with 1.0 always true" {
    var rng = PRNG.init(456);

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try testing.expect(rng.next_bool(1.0));
    }
}

test "PRNG: next_u64 generates 64-bit values" {
    var rng = PRNG.init(789);

    const value = rng.next_u64();
    try testing.expect(value > std.math.maxInt(u32));
}

test "PRNG: fill_bytes fills entire buffer" {
    var rng = PRNG.init(111);
    var buffer: [100]u8 = undefined;

    rng.fill_bytes(&buffer);

    // Check that not all bytes are zero (statistical check)
    var non_zero_count: u32 = 0;
    for (buffer) |byte| {
        if (byte != 0) non_zero_count += 1;
    }

    try testing.expect(non_zero_count > 90); // At least 90% non-zero
}

test "PRNG: shuffle permutes array" {
    var rng = PRNG.init(222);
    var array = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const original = array;

    rng.shuffle(u32, &array);

    // Check that array contains same elements
    var found = [_]bool{false} ** 10;
    for (array) |value| {
        found[value] = true;
    }

    for (found) |f| {
        try testing.expect(f);
    }

    // Check that order changed (statistical check)
    var different_count: u32 = 0;
    for (array, 0..) |value, i| {
        if (value != original[i]) different_count += 1;
    }

    try testing.expect(different_count > 5); // At least 50% different positions
}
