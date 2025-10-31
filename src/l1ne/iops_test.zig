//! Comprehensive tests for IOPSType and BitSet
//!
//! These tests verify:
//! - BitSet operations (set, unset, first_unset, count, is_set)
//! - IOPSType acquire/release semantics
//! - Pool exhaustion and backpressure
//! - Pointer arithmetic correctness
//! - Invariant validation

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const iops = @import("iops.zig");
const BitSet = iops.BitSet;
const IOPSType = iops.IOPSType;

// Test helper struct
const TestItem = struct {
    value: u64,
    id: u32,
};

// Test: BitSet initialization

// Verifies:
//   - Default initialization creates empty bitset
//   - All bits are unset (count == 0)
//   - First unset returns index 0
test "BitSet: initialization" {
    const bs: BitSet = .{};

    try testing.expectEqual(@as(u7, 0), bs.count());
    try testing.expectEqual(@as(?u6, 0), bs.first_unset());
    try testing.expect(!bs.is_set(0));
    try testing.expect(!bs.is_set(63));
}

// Test: BitSet set and unset operations

// Verifies:
//   - Setting bits marks them as busy
//   - Unsetting bits marks them as free
//   - Count updates correctly
//   - is_set returns correct state
test "BitSet: set and unset operations" {
    var bs: BitSet = .{};

    // Set bit 0
    bs.set(0);
    try testing.expect(bs.is_set(0));
    try testing.expectEqual(@as(u7, 1), bs.count());

    // Set bit 5
    bs.set(5);
    try testing.expect(bs.is_set(5));
    try testing.expectEqual(@as(u7, 2), bs.count());

    // Set bit 63 (boundary)
    bs.set(63);
    try testing.expect(bs.is_set(63));
    try testing.expectEqual(@as(u7, 3), bs.count());

    // Unset bit 5
    bs.unset(5);
    try testing.expect(!bs.is_set(5));
    try testing.expectEqual(@as(u7, 2), bs.count());

    // Verify others still set
    try testing.expect(bs.is_set(0));
    try testing.expect(bs.is_set(63));
}

// Test: BitSet first_unset correctness

// Verifies:
//   - first_unset returns lowest free bit index
//   - Returns null when all bits set
//   - Handles gaps correctly
test "BitSet: first_unset correctness" {
    var bs: BitSet = .{};

    // Initially returns 0
    try testing.expectEqual(@as(?u6, 0), bs.first_unset());

    // Set bit 0, should return 1
    bs.set(0);
    try testing.expectEqual(@as(?u6, 1), bs.first_unset());

    // Set bits 1-4, should return 5
    bs.set(1);
    bs.set(2);
    bs.set(3);
    bs.set(4);
    try testing.expectEqual(@as(?u6, 5), bs.first_unset());

    // Set all bits except 10
    var i: u8 = 0;
    while (i < 64) : (i += 1) {
        const idx: u6 = @intCast(i);
        if (i != 10) {
            if (!bs.is_set(idx)) bs.set(idx);
        }
    }
    try testing.expectEqual(@as(?u6, 10), bs.first_unset());

    // Set bit 10, should return null (all full)
    bs.set(10);
    try testing.expectEqual(@as(?u6, null), bs.first_unset());
    try testing.expectEqual(@as(u7, 64), bs.count());
}

// Test: BitSet full pool scenario

// Verifies:
//   - Can set all 64 bits
//   - first_unset returns null when full
//   - count returns 64
test "BitSet: full pool scenario" {
    var bs: BitSet = .{};

    // Set all 64 bits
    var i: u8 = 0;
    while (i < 64) : (i += 1) {
        const idx: u6 = @intCast(i);
        bs.set(idx);
    }

    try testing.expectEqual(@as(u7, 64), bs.count());
    try testing.expectEqual(@as(?u6, null), bs.first_unset());

    // Verify all bits are set
    i = 0;
    while (i < 64) : (i += 1) {
        const idx: u6 = @intCast(i);
        try testing.expect(bs.is_set(idx));
    }
}

// Test: IOPSType initialization

// Verifies:
//   - Pool initializes as empty
//   - All slots are free
//   - busy_count and free_count are correct
test "IOPSType: initialization" {
    var pool: IOPSType(TestItem, 8) = .{};

    try testing.expectEqual(@as(u7, 0), pool.busy_count());
    try testing.expectEqual(@as(u8, 8), pool.free_count());
    try testing.expect(pool.is_empty());
    try testing.expect(!pool.is_full());
}

// Test: IOPSType acquire and release

// Verifies:
//   - acquire returns valid pointer
//   - busy_count increases after acquire
//   - release decreases busy_count
//   - Can reuse released slots
test "IOPSType: acquire and release" {
    var pool: IOPSType(TestItem, 4) = .{};

    // Acquire first slot
    const item1 = pool.acquire().?;
    item1.value = 42;
    item1.id = 1;
    try testing.expectEqual(@as(u7, 1), pool.busy_count());
    try testing.expectEqual(@as(u8, 3), pool.free_count());

    // Acquire second slot
    const item2 = pool.acquire().?;
    item2.value = 100;
    item2.id = 2;
    try testing.expectEqual(@as(u7, 2), pool.busy_count());

    // Release first slot
    pool.release(item1);
    try testing.expectEqual(@as(u7, 1), pool.busy_count());
    try testing.expectEqual(@as(u8, 3), pool.free_count());

    // Acquire again (should reuse slot)
    const item3 = pool.acquire().?;
    item3.value = 200;
    item3.id = 3;
    try testing.expectEqual(@as(u7, 2), pool.busy_count());

    // Release all
    pool.release(item2);
    pool.release(item3);
    try testing.expect(pool.is_empty());
}

// Test: IOPSType pool exhaustion

// Verifies:
//   - acquire returns null when pool is full
//   - Natural backpressure mechanism
//   - Pool state is correct when full
test "IOPSType: pool exhaustion" {
    var pool: IOPSType(TestItem, 4) = .{};

    // Acquire all 4 slots
    const item1 = pool.acquire().?;
    const item2 = pool.acquire().?;
    const item3 = pool.acquire().?;
    const item4 = pool.acquire().?;

    try testing.expect(pool.is_full());
    try testing.expectEqual(@as(u7, 4), pool.busy_count());
    try testing.expectEqual(@as(u8, 0), pool.free_count());

    // Next acquire should return null
    const item5 = pool.acquire();
    try testing.expectEqual(@as(?*TestItem, null), item5);

    // Release one slot
    pool.release(item2);
    try testing.expect(!pool.is_full());
    try testing.expectEqual(@as(u8, 1), pool.free_count());

    // Should be able to acquire again
    const item6 = pool.acquire();
    try testing.expect(item6 != null);
    try testing.expect(pool.is_full());

    // Clean up
    pool.release(item1);
    pool.release(item3);
    pool.release(item4);
    pool.release(item6.?);
}

// Test: IOPSType pointer arithmetic

// Verifies:
//   - index() returns correct slot index
//   - Acquired pointers are within array bounds
//   - Indices match acquisition order
test "IOPSType: pointer arithmetic" {
    var pool: IOPSType(TestItem, 8) = .{};

    // Acquire all slots and verify indices
    var items: [8]*TestItem = undefined;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        items[i] = pool.acquire().?;
        const idx = pool.index(items[i]);
        try testing.expectEqual(@as(u8, @intCast(i)), idx);
    }

    // Verify pool is full
    try testing.expect(pool.is_full());

    // Release in reverse order and verify
    var j: usize = 8;
    while (j > 0) {
        j -= 1;
        pool.release(items[j]);
    }

    try testing.expect(pool.is_empty());
}

// Test: IOPSType acquire/release pattern

// Verifies:
//   - Can acquire and release multiple times
//   - Pool state remains consistent
//   - No memory corruption
test "IOPSType: acquire/release pattern" {
    var pool: IOPSType(TestItem, 16) = .{};

    // Acquire half the pool
    var items: [8]*TestItem = undefined;
    for (&items) |*item| {
        item.* = pool.acquire().?;
    }
    try testing.expectEqual(@as(u7, 8), pool.busy_count());

    // Release half
    for (items[0..4]) |item| {
        pool.release(item);
    }
    try testing.expectEqual(@as(u7, 4), pool.busy_count());

    // Acquire more
    var more_items: [6]*TestItem = undefined;
    for (&more_items) |*item| {
        item.* = pool.acquire().?;
    }
    try testing.expectEqual(@as(u7, 10), pool.busy_count());

    // Release all
    for (items[4..8]) |item| {
        pool.release(item);
    }
    for (more_items) |item| {
        pool.release(item);
    }
    try testing.expect(pool.is_empty());
}

// Test: IOPSType data integrity

// Verifies:
//   - Data written to slots persists
//   - No cross-slot corruption
//   - Released and reacquired slots work correctly
test "IOPSType: data integrity" {
    var pool: IOPSType(TestItem, 4) = .{};

    // Acquire and write unique values
    const item1 = pool.acquire().?;
    item1.value = 1111;
    item1.id = 1;

    const item2 = pool.acquire().?;
    item2.value = 2222;
    item2.id = 2;

    const item3 = pool.acquire().?;
    item3.value = 3333;
    item3.id = 3;

    // Verify values
    try testing.expectEqual(@as(u64, 1111), item1.value);
    try testing.expectEqual(@as(u64, 2222), item2.value);
    try testing.expectEqual(@as(u64, 3333), item3.value);

    // Release middle item
    pool.release(item2);

    // Verify other items unchanged
    try testing.expectEqual(@as(u64, 1111), item1.value);
    try testing.expectEqual(@as(u64, 3333), item3.value);

    // Acquire new item (should reuse item2's slot)
    const item4 = pool.acquire().?;
    item4.value = 4444;
    item4.id = 4;

    // Verify all values
    try testing.expectEqual(@as(u64, 1111), item1.value);
    try testing.expectEqual(@as(u64, 4444), item4.value);
    try testing.expectEqual(@as(u64, 3333), item3.value);

    // Clean up
    pool.release(item1);
    pool.release(item3);
    pool.release(item4);
}

// Test: IOPSType boundary conditions

// Verifies:
//   - Minimum pool size (1) works
//   - Maximum pool size (64) works
//   - Edge case handling
test "IOPSType: boundary conditions" {
    // Test pool size 1
    var pool1: IOPSType(TestItem, 1) = .{};
    const item1 = pool1.acquire().?;
    try testing.expect(pool1.is_full());
    const item2 = pool1.acquire();
    try testing.expectEqual(@as(?*TestItem, null), item2);
    pool1.release(item1);
    try testing.expect(pool1.is_empty());

    // Test pool size 64 (maximum)
    var pool64: IOPSType(TestItem, 64) = .{};
    try testing.expectEqual(@as(u8, 64), pool64.free_count());

    // Acquire all 64 slots
    var items64: [64]*TestItem = undefined;
    for (&items64) |*item| {
        item.* = pool64.acquire().?;
    }
    try testing.expect(pool64.is_full());

    // Try to acquire one more (should fail)
    const overflow = pool64.acquire();
    try testing.expectEqual(@as(?*TestItem, null), overflow);

    // Release all
    for (items64) |item| {
        pool64.release(item);
    }
    try testing.expect(pool64.is_empty());
}
