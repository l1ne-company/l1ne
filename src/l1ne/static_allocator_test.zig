//! Comprehensive tests for StaticAllocator
//!
//! These tests verify:
//! - Two-phase allocation (INIT → STATIC)
//! - Allocation tracking and accounting
//! - State transitions
//! - Error conditions
//! - Memory safety guarantees

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const static_allocator_mod = @import("static_allocator.zig");
const StaticAllocator = static_allocator_mod.StaticAllocator;

// Test: StaticAllocator initialization

// Verifies:
//   - Initializes in INIT state
//   - Total allocated is 0
//   - State queries work correctly
test "StaticAllocator: initialization" {
    var static_alloc = StaticAllocator.init(testing.allocator);

    try testing.expectEqual(StaticAllocator.State.init, static_alloc.get_state());
    try testing.expect(!static_alloc.is_static());
    try testing.expectEqual(@as(u64, 0), static_alloc.get_total_allocated());
}

// Test: StaticAllocator INIT phase allocation

// Verifies:
//   - Can allocate in INIT state
//   - Total allocated increases correctly
//   - Multiple allocations work
test "StaticAllocator: INIT phase allocation" {
    var static_alloc = StaticAllocator.init(testing.allocator);
    const allocator = static_alloc.allocator();

    // Allocate first buffer
    const buf1 = try allocator.alloc(u8, 1024);
    defer allocator.free(buf1);
    try testing.expectEqual(@as(usize, 1024), buf1.len);
    try testing.expect(static_alloc.get_total_allocated() >= 1024);

    const allocated_after_buf1 = static_alloc.get_total_allocated();

    // Allocate second buffer
    const buf2 = try allocator.alloc(u8, 2048);
    defer allocator.free(buf2);
    try testing.expectEqual(@as(usize, 2048), buf2.len);
    try testing.expect(static_alloc.get_total_allocated() >= allocated_after_buf1 + 2048);

    // Verify still in INIT state
    try testing.expectEqual(StaticAllocator.State.init, static_alloc.get_state());
    try testing.expect(!static_alloc.is_static());
}

// Test: StaticAllocator transition to STATIC

// Verifies:
//   - Can transition from INIT to STATIC
//   - State changes correctly
//   - Transition is irreversible
test "StaticAllocator: transition to STATIC" {
    var static_alloc = StaticAllocator.init(testing.allocator);
    const allocator = static_alloc.allocator();

    // Must allocate something before transitioning
    const buf = try allocator.alloc(u8, 512);
    try testing.expectEqual(@as(usize, 512), buf.len);

    // Verify in INIT state
    try testing.expect(!static_alloc.is_static());

    const total_before = static_alloc.get_total_allocated();

    // Transition to STATIC
    static_alloc.transition_to_static();

    // Verify in STATIC state
    try testing.expectEqual(StaticAllocator.State.static, static_alloc.get_state());
    try testing.expect(static_alloc.is_static());

    // Total allocated should be non-zero and unchanged
    try testing.expect(static_alloc.get_total_allocated() > 0);
    try testing.expectEqual(total_before, static_alloc.get_total_allocated());

    // In STATIC mode, memory stays allocated for program lifetime
    // Only free here to satisfy test allocator leak detection
    allocator.free(buf);
}

// Test: StaticAllocator allocation tracking

// Verifies:
//   - Total allocated increases on allocation
//   - Total allocated decreases on free
//   - Accounting is accurate
test "StaticAllocator: allocation tracking" {
    var static_alloc = StaticAllocator.init(testing.allocator);
    const allocator = static_alloc.allocator();

    try testing.expectEqual(@as(u64, 0), static_alloc.get_total_allocated());

    // Allocate 1 KiB
    const buf1 = try allocator.alloc(u8, 1024);
    const after_buf1 = static_alloc.get_total_allocated();
    try testing.expect(after_buf1 >= 1024);

    // Allocate 2 KiB
    const buf2 = try allocator.alloc(u8, 2048);
    const after_buf2 = static_alloc.get_total_allocated();
    try testing.expect(after_buf2 >= after_buf1 + 2048);

    // Free first buffer
    allocator.free(buf1);
    const after_free1 = static_alloc.get_total_allocated();
    try testing.expect(after_free1 < after_buf2);
    try testing.expect(after_free1 >= 2048);

    // Free second buffer
    allocator.free(buf2);
    const after_free2 = static_alloc.get_total_allocated();
    try testing.expect(after_free2 < after_free1);
}

// Test: StaticAllocator multiple allocation types

// Verifies:
//   - Can allocate different types
//   - Alignment is respected
//   - Total accounting is correct
test "StaticAllocator: multiple allocation types" {
    var static_alloc = StaticAllocator.init(testing.allocator);
    const allocator = static_alloc.allocator();

    // Allocate u8 array
    const u8_array = try allocator.alloc(u8, 100);
    defer allocator.free(u8_array);
    try testing.expectEqual(@as(usize, 100), u8_array.len);

    // Allocate u64 array (requires 8-byte alignment)
    const u64_array = try allocator.alloc(u64, 50);
    defer allocator.free(u64_array);
    try testing.expectEqual(@as(usize, 50), u64_array.len);
    try testing.expect(@intFromPtr(u64_array.ptr) % @alignOf(u64) == 0);

    // Allocate struct
    const Point = struct { x: i32, y: i32 };
    const points = try allocator.alloc(Point, 10);
    defer allocator.free(points);
    try testing.expectEqual(@as(usize, 10), points.len);
    try testing.expect(@intFromPtr(points.ptr) % @alignOf(Point) == 0);

    // Verify total allocated is non-zero
    try testing.expect(static_alloc.get_total_allocated() > 0);
}

// Test: StaticAllocator create and destroy

// Verifies:
//   - Can use create and destroy
//   - Single item allocation works
//   - Accounting updates correctly
test "StaticAllocator: create and destroy" {
    var static_alloc = StaticAllocator.init(testing.allocator);
    const allocator = static_alloc.allocator();

    const TestStruct = struct {
        value: u64,
        name: [16]u8,
    };

    // Create single item
    const item = try allocator.create(TestStruct);
    defer allocator.destroy(item);

    item.value = 42;
    try testing.expectEqual(@as(u64, 42), item.value);

    // Verify accounting
    try testing.expect(static_alloc.get_total_allocated() >= @sizeOf(TestStruct));
}

// Test: StaticAllocator dupe functionality

// Verifies:
//   - Can duplicate slices
//   - Duplicated data is independent
//   - Accounting is correct
test "StaticAllocator: dupe functionality" {
    var static_alloc = StaticAllocator.init(testing.allocator);
    const allocator = static_alloc.allocator();

    const original = "Hello, World!";
    const duplicated = try allocator.dupe(u8, original);
    defer allocator.free(duplicated);

    // Verify content matches
    try testing.expectEqualStrings(original, duplicated);

    // Verify they are different memory
    try testing.expect(@intFromPtr(original.ptr) != @intFromPtr(duplicated.ptr));

    // Modify duplicate and verify original unchanged
    duplicated[0] = 'h';
    try testing.expect(original[0] == 'H');
    try testing.expect(duplicated[0] == 'h');
}

// Test: StaticAllocator state queries

// Verifies:
//   - get_state returns correct state
//   - is_static returns correct boolean
//   - Both are consistent
test "StaticAllocator: state queries" {
    var static_alloc = StaticAllocator.init(testing.allocator);
    const allocator = static_alloc.allocator();

    // In INIT state
    try testing.expectEqual(StaticAllocator.State.init, static_alloc.get_state());
    try testing.expect(!static_alloc.is_static());

    // Allocate something to allow transition
    const buf = try allocator.alloc(u8, 256);
    try testing.expectEqual(@as(usize, 256), buf.len);

    // Transition to STATIC
    static_alloc.transition_to_static();

    // In STATIC state
    try testing.expectEqual(StaticAllocator.State.static, static_alloc.get_state());
    try testing.expect(static_alloc.is_static());

    // In STATIC mode, memory stays allocated for program lifetime
    // Only free here to satisfy test allocator leak detection
    allocator.free(buf);
}

// Test: StaticAllocator accounting edge cases

// Verifies:
//   - Free before any allocation works
//   - Multiple frees don't underflow
//   - Accounting stays consistent
test "StaticAllocator: accounting edge cases" {
    var static_alloc = StaticAllocator.init(testing.allocator);
    const allocator = static_alloc.allocator();

    // Allocate and immediately free
    const buf1 = try allocator.alloc(u8, 100);
    allocator.free(buf1);

    // Should be close to 0 after free
    const after_free = static_alloc.get_total_allocated();
    try testing.expect(after_free < 100);

    // Allocate multiple, free all
    const buf2 = try allocator.alloc(u8, 200);
    const buf3 = try allocator.alloc(u8, 300);
    const buf4 = try allocator.alloc(u8, 400);

    allocator.free(buf2);
    allocator.free(buf3);
    allocator.free(buf4);

    // Should be low again
    const final_allocated = static_alloc.get_total_allocated();
    try testing.expect(final_allocated < 1000);
}

// Test: StaticAllocator backed by page allocator

// Verifies:
//   - Works with different backing allocators
//   - Can allocate large amounts
//   - Accounting is correct
test "StaticAllocator: with page allocator" {
    var static_alloc = StaticAllocator.init(std.heap.page_allocator);
    const allocator = static_alloc.allocator();

    // Allocate large buffer (1 MiB)
    const large_buf = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(large_buf);

    try testing.expectEqual(@as(usize, 1024 * 1024), large_buf.len);
    try testing.expect(static_alloc.get_total_allocated() >= 1024 * 1024);

    // Verify in INIT state
    try testing.expect(!static_alloc.is_static());
}

// Test: StaticAllocator realistic usage pattern

// Verifies:
//   - Typical usage flow works correctly
//   - Transition happens at right time
//   - All allocations in INIT phase succeed
//   - Memory stays allocated in STATIC mode (TigerStyle)
test "StaticAllocator: realistic usage pattern" {
    var static_alloc = StaticAllocator.init(testing.allocator);
    const allocator = static_alloc.allocator();

    // Phase 1 (INIT): Allocate all needed memory
    const config_buf = try allocator.alloc(u8, 4096);
    const proxy_bufs = try allocator.alloc([4096]u8, 16);
    const metadata = try allocator.alloc(u64, 1024);

    // Verify all allocations succeeded
    try testing.expectEqual(@as(usize, 4096), config_buf.len);
    try testing.expectEqual(@as(usize, 16), proxy_bufs.len);
    try testing.expectEqual(@as(usize, 1024), metadata.len);

    const total_before_transition = static_alloc.get_total_allocated();
    try testing.expect(total_before_transition > 0);

    // Phase 2: Transition to STATIC
    static_alloc.transition_to_static();
    try testing.expect(static_alloc.is_static());

    // Total allocated should remain the same (no deallocation in STATIC mode)
    const total_after_transition = static_alloc.get_total_allocated();
    try testing.expectEqual(total_before_transition, total_after_transition);

    // In STATIC mode, memory stays allocated for program lifetime
    // Only free here to satisfy test allocator leak detection
    allocator.free(config_buf);
    allocator.free(proxy_bufs);
    allocator.free(metadata);
}
