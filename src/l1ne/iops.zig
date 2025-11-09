//! IOPS (I/O Operations) - Bounded concurrent operation pools
//!
//! This module implements the TigerBeetle IOPSType pattern for static memory allocation.
//! Instead of dynamic allocation, we pre-allocate a fixed-size array and track which
//! slots are busy using a bitset. This provides:
//!
//! - O(1) acquire/release operations
//! - Natural backpressure (acquire returns null when pool exhausted)
//! - Zero allocation after initialization
//! - Deterministic memory usage
//!
//! Example:
//!   var reads: IOPSType(Read, 64) = .{};
//!   const read = reads.acquire() orelse return error.Busy;
//!   defer reads.release(read);

const std = @import("std");
const assert = std.debug.assert;

/// BitSet for tracking which slots in an IOPs pool are busy
///
/// Invariants:
///   - bits represents busy/free state: 1 = busy, 0 = free
///   - Valid bit count: 0 to 64 (limited by u64 storage)
///   - Each bit position corresponds to an array index
///
/// Performance:
///   - first_unset(): O(1) using hardware @ctz instruction
///   - set()/unset(): O(1) bitwise operations
///   - count(): O(1) using hardware @popCount instruction
pub const BitSet = struct {
    /// Bits are packed into u64 words
    /// For pools <= 64 slots, this is just one u64
    /// For larger pools, we'd need an array of u64s
    bits: u64 = 0,

    /// Find first unset (free) bit, return its index
    /// Returns null if all bits are set (pool is full)
    ///
    /// Invariants:
    ///   - Pre: self.bits is valid u64
    ///   - Post: returned index is < 64, or null if all bits set
    ///   - Does not modify state
    pub fn first_unset(self: *const BitSet, active_bits: u7) ?u6 {
        assert(active_bits > 0 and active_bits <= 64);

        const mask: u64 = if (active_bits == 64)
            std.math.maxInt(u64)
        else blk: {
            const capped_bits: u6 = @intCast(active_bits);
            break :blk (@as(u64, 1) << capped_bits) - 1;
        };

        const inverted = (~self.bits) & mask;
        if (inverted == 0) {
            return null;
        }

        const index = @ctz(inverted);
        assert(index < active_bits);
        return @intCast(index);
    }

    /// Set bit at index (mark slot as busy)
    ///
    /// Invariants:
    ///   - Pre: index < 64
    ///   - Pre: bit at index must be 0 (not already busy)
    ///   - Post: bit at index is 1
    ///   - Post: count increases by 1
    pub fn set(self: *BitSet, index: u6) void {
        assert(index < 64); // Bounds check
        assert(!self.is_set(index)); // Must not be already set (double acquire)

        const old_count = self.count();
        self.bits |= (@as(u64, 1) << index);

        assert(self.is_set(index)); // Verify bit was set
        assert(self.count() == old_count + 1); // Count increased by exactly 1
    }

    /// Unset bit at index (mark slot as free)
    ///
    /// Invariants:
    ///   - Pre: index < 64
    ///   - Pre: bit at index must be 1 (currently busy)
    ///   - Post: bit at index is 0
    ///   - Post: count decreases by 1
    pub fn unset(self: *BitSet, index: u6) void {
        assert(index < 64); // Bounds check
        assert(self.is_set(index)); // Must be set (double release)

        const old_count = self.count();
        assert(old_count > 0); // Must have at least one bit set
        self.bits &= ~(@as(u64, 1) << index);

        assert(!self.is_set(index)); // Verify bit was unset
        assert(self.count() == old_count - 1); // Count decreased by exactly 1
    }

    /// Check if bit at index is set
    ///
    /// Invariants:
    ///   - Pre: index < 64
    ///   - Does not modify state
    pub fn is_set(self: *const BitSet, index: u6) bool {
        assert(index < 64); // Bounds check
        return (self.bits & (@as(u64, 1) << index)) != 0;
    }

    /// Count number of set bits (busy slots)
    ///
    /// Invariants:
    ///   - Post: result is 0 to 64 (inclusive)
    ///   - Does not modify state
    pub fn count(self: *const BitSet) u7 {
        const result = @popCount(self.bits);
        assert(result <= 64); // Cannot have more than 64 bits set
        return result;
    }
};

/// IOPSType creates a bounded pool of T with fixed capacity
///
/// This is the core pattern for static allocation in L1NE. Instead of malloc/free,
/// we acquire/release slots from a pre-allocated array.
///
/// Params:
///   T: Type to store in the pool
///   capacity: Maximum number of concurrent operations (must be <= 64)
pub fn IOPSType(comptime T: type, comptime capacity: u8) type {
    // Enforce NASA constraint: explicit limits on everything
    assert(capacity > 0); // Must have at least one slot
    assert(capacity <= 64); // Current BitSet implementation supports max 64

    return struct {
        items: [capacity]T = undefined,
        busy: BitSet = .{},
        active_slots: u7 = capacity,

        const IOPS = @This();

        /// Acquire a free slot from the pool
        /// Returns null if all slots are busy (provides natural backpressure)
        ///
        /// Invariants:
        ///   - Pre: self is valid pointer
        ///   - Pre: busy_count <= capacity
        ///   - Post: busy_count increases by 1 if successful
        ///   - Post: returned pointer is within items array bounds
        ///   - Post: returned pointer is properly aligned for T
        ///
        /// Performance: O(1) - hardware @ctz instruction
        pub fn acquire(self: *IOPS) ?*T {
            assert(@intFromPtr(self) != 0); // Self must be valid
            assert(self.active_slots > 0 and self.active_slots <= capacity);

            const old_busy = self.busy_count();
            assert(old_busy <= self.active_slots); // Cannot exceed configured limit

            const slot_index = self.busy.first_unset(self.active_slots) orelse {
                assert(old_busy == self.active_slots); // Active region fully busy
                return null;
            };

            assert(slot_index < capacity); // Index must be in bounds
            self.busy.set(slot_index);

            const result = &self.items[slot_index];
            assert(@intFromPtr(result) != 0); // Result must be valid
            assert(@intFromPtr(result) % @alignOf(T) == 0); // Must be properly aligned
            assert(self.busy_count() == old_busy + 1); // Busy count increased

            return result;
        }

        /// Release a slot back to the pool
        /// Item must have been acquired from this pool
        ///
        /// Invariants:
        ///   - Pre: self and item are valid pointers
        ///   - Pre: item points to a slot within this pool's items array
        ///   - Pre: slot at item's index must be busy
        ///   - Pre: busy_count > 0
        ///   - Post: busy_count decreases by 1
        ///   - Post: slot at item's index is free
        ///
        /// Performance: O(1) - pointer arithmetic + bit clear
        pub fn release(self: *IOPS, item: *T) void {
            assert(@intFromPtr(self) != 0); // Self must be valid
            assert(@intFromPtr(item) != 0); // Item must be valid

            const old_busy = self.busy_count();
            assert(old_busy > 0); // Must have at least one busy slot

            const slot_index = self.index(item);
            assert(slot_index < capacity); // Index must be in bounds
            assert(slot_index < self.active_slots); // Must be within active region
            assert(self.busy.is_set(@intCast(slot_index))); // Slot must be busy

            self.busy.unset(@intCast(slot_index));

            assert(!self.busy.is_set(@intCast(slot_index))); // Verify slot is now free
            assert(self.busy_count() == old_busy - 1); // Busy count decreased
        }

        /// Get index of an item in the pool using pointer arithmetic
        ///
        /// Invariants:
        ///   - Pre: self and item are valid pointers
        ///   - Pre: item points within items array bounds
        ///   - Post: returned index < capacity
        ///   - Does not modify state
        ///
        /// Performance: O(1) - division and pointer subtraction
        pub fn index(self: *IOPS, item: *T) u8 {
            assert(@intFromPtr(self) != 0); // Self must be valid
            assert(@intFromPtr(item) != 0); // Item must be valid

            const array_base = @intFromPtr(&self.items[0]);
            const item_addr = @intFromPtr(item);

            // Item must be within the array bounds
            assert(item_addr >= array_base);
            assert(item_addr < array_base + (@sizeOf(T) * @as(usize, capacity)));

            // Must be properly aligned
            assert((item_addr - array_base) % @sizeOf(T) == 0);

            const offset = item_addr - array_base;
            const idx = offset / @sizeOf(T);

            assert(idx < capacity); // Result must be in bounds
            return @intCast(idx);
        }

        /// Get number of busy slots
        ///
        /// Invariants:
        ///   - Post: result is 0 to capacity (inclusive)
        ///   - Does not modify state
        pub fn busy_count(self: *const IOPS) u7 {
            const result = self.busy.count();
            assert(result <= capacity);
            assert(result <= self.active_slots);
            return result;
        }

        pub fn capacity_total(self: *const IOPS) usize {
            _ = self;
            return capacity;
        }

        pub fn activeCapacity(self: *const IOPS) usize {
            return self.active_slots;
        }

        pub fn configureActiveSlots(self: *IOPS, new_active: u7) void {
            assert(new_active > 0);
            assert(new_active <= capacity);
            assert(self.busy_count() <= new_active);
            self.active_slots = new_active;
        }

        /// Get number of free slots
        ///
        /// Invariants:
        ///   - Post: result is 0 to capacity (inclusive)
        ///   - Post: result + busy_count() == capacity
        ///   - Does not modify state
        pub fn free_count(self: *const IOPS) u8 {
            const busy_cnt = self.busy_count();
            assert(busy_cnt <= self.active_slots); // Sanity check
            const free_cnt = self.active_slots - busy_cnt;
            assert(free_cnt + busy_cnt == self.active_slots); // Must sum to active slots
            return free_cnt;
        }

        /// Check if pool is full (no free slots)
        ///
        /// Invariants:
        ///   - Post: result == (free_count() == 0)
        ///   - Does not modify state
        pub fn is_full(self: *const IOPS) bool {
            const result = self.free_count() == 0;
            assert(result == (self.busy_count() == self.active_slots)); // Consistent definition
            return result;
        }

        /// Check if pool is empty (all slots free)
        ///
        /// Invariants:
        ///   - Post: result == (busy_count() == 0)
        ///   - Does not modify state
        pub fn is_empty(self: *const IOPS) bool {
            const result = self.busy_count() == 0;
            assert(result == (self.free_count() == self.active_slots)); // Consistent definition
            return result;
        }
    };
}

// Compile-time tests
comptime {
    // Test that IOPSType can be instantiated with various sizes
    _ = IOPSType(u32, 1);
    _ = IOPSType(u32, 32);
    _ = IOPSType(u32, 64);

    // Test that BitSet size is reasonable
    assert(@sizeOf(BitSet) == 8); // Just one u64
}

test "BitSet: set and unset bits" {
    var bs: BitSet = .{};

    // Initially all bits should be unset
    try std.testing.expectEqual(@as(u7, 0), bs.count());

    // Set some bits
    bs.set(0);
    try std.testing.expect(bs.is_set(0));
    try std.testing.expectEqual(@as(u7, 1), bs.count());

    bs.set(5);
    try std.testing.expect(bs.is_set(5));
    try std.testing.expectEqual(@as(u7, 2), bs.count());

    // Unset a bit
    bs.unset(0);
    try std.testing.expect(!bs.is_set(0));
    try std.testing.expectEqual(@as(u7, 1), bs.count());
}

test "BitSet: first_unset finds correct index" {
    var bs: BitSet = .{};

    // Initially should return 0
    try std.testing.expectEqual(@as(?u6, 0), bs.first_unset(64));

    // Set bit 0, should return 1
    bs.set(0);
    try std.testing.expectEqual(@as(?u6, 1), bs.first_unset(64));

    // Set bit 1, should return 2
    bs.set(1);
    try std.testing.expectEqual(@as(?u6, 2), bs.first_unset(64));

    // Set all bits except 5, should return 5
    bs.bits = std.math.maxInt(u64) & ~(@as(u64, 1) << 5);
    try std.testing.expectEqual(@as(?u6, 5), bs.first_unset(64));

    // Set all bits, should return null
    bs.bits = std.math.maxInt(u64);
    try std.testing.expectEqual(@as(?u6, null), bs.first_unset(64));
}

test "BitSet: first_unset respects active limit" {
    var bs: BitSet = .{};
    // Leave bit 0 free, fill others
    bs.bits = std.math.maxInt(u64) & ~(@as(u64, 1) << 0);
    try std.testing.expectEqual(@as(?u6, 0), bs.first_unset(64));

    // Limit to 0 active bits should be invalid (handled by assert), so use 8 and block first slot
    bs.set(0);
    try std.testing.expectEqual(@as(?u6, null), bs.first_unset(1));
}

test "IOPSType: acquire and release" {
    const TestStruct = struct { value: u32 };
    var pool: IOPSType(TestStruct, 4) = .{};

    // Initially all slots should be free
    try std.testing.expectEqual(@as(u8, 4), pool.free_count());
    try std.testing.expectEqual(@as(u7, 0), pool.busy_count());
    try std.testing.expect(!pool.is_full());
    try std.testing.expect(pool.is_empty());

    // Acquire first slot
    const item1 = pool.acquire().?;
    item1.value = 42;
    try std.testing.expectEqual(@as(u8, 3), pool.free_count());
    try std.testing.expectEqual(@as(u7, 1), pool.busy_count());

    // Acquire second slot
    const item2 = pool.acquire().?;
    item2.value = 100;
    try std.testing.expectEqual(@as(u8, 2), pool.free_count());

    // Acquire remaining slots
    const item3 = pool.acquire().?;
    const item4 = pool.acquire().?;
    try std.testing.expectEqual(@as(u8, 0), pool.free_count());
    try std.testing.expect(pool.is_full());
    try std.testing.expect(!pool.is_empty());

    // Try to acquire from full pool - should return null
    const item5 = pool.acquire();
    try std.testing.expectEqual(@as(?*TestStruct, null), item5);

    // Release a slot
    pool.release(item2);
    try std.testing.expectEqual(@as(u8, 1), pool.free_count());
    try std.testing.expect(!pool.is_full());

    // Should be able to acquire again
    const item6 = pool.acquire().?;
    try std.testing.expectEqual(@as(u8, 0), pool.free_count());

    // Release all
    pool.release(item1);
    pool.release(item3);
    pool.release(item4);
    pool.release(item6);
    try std.testing.expectEqual(@as(u8, 4), pool.free_count());
    try std.testing.expect(pool.is_empty());
}

test "IOPSType: pointer arithmetic index calculation" {
    const TestStruct = struct { value: u32 };
    var pool: IOPSType(TestStruct, 8) = .{};

    // Acquire all slots and verify indices
    var items: [8]*TestStruct = undefined;
    for (&items, 0..) |*slot, i| {
        slot.* = pool.acquire().?;
        try std.testing.expectEqual(@as(u8, @intCast(i)), pool.index(slot.*));
    }

    // Release in reverse order
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        pool.release(items[i]);
    }

    try std.testing.expect(pool.is_empty());
}

test "IOPSType: active slot configuration" {
    const TestStruct = struct { value: u32 };
    var pool: IOPSType(TestStruct, 8) = .{};

    pool.configureActiveSlots(4);
    try std.testing.expectEqual(@as(usize, 4), pool.activeCapacity());

    // Acquire up to active limit
    var ptrs: [4]*TestStruct = undefined;
    for (&ptrs, 0..) |*slot, i| {
        slot.* = pool.acquire().?;
        slot.*.value = @intCast(i);
    }

    // Further acquire should fail because active region full
    try std.testing.expect(pool.acquire() == null);

    // Releasing one frees capacity
    pool.release(ptrs[0]);
    try std.testing.expect(pool.acquire() != null);
}
