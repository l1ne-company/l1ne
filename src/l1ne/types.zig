const std = @import("std");
const assert = std.debug.assert;
const net = std.net;

// Memory size constants
pub const KIB = 1 << 10;
pub const MIB = 1 << 20;
pub const GIB = 1 << 30;

// Time constants (nanoseconds)
pub const NANOSEC = 1;
pub const MICROSEC = 1_000;
pub const MILLISEC = 1_000_000;
pub const SEC = 1_000_000_000;

comptime {
    assert(KIB == 1024);
    assert(MIB == 1024 * KIB);
    assert(GIB == 1024 * MIB);

    assert(MICROSEC == 1_000 * NANOSEC);
    assert(MILLISEC == 1_000 * MICROSEC);
    assert(SEC == 1_000 * MILLISEC);
}

/// BoundedArray - Fixed-capacity array with runtime length
/// This is extracted from cli.zig for use throughout the codebase
pub fn BoundedArray(comptime T: type, comptime capacity: usize) type {
    assert(capacity > 0); // Must have non-zero capacity

    return struct {
        items: [capacity]T = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        pub fn push(self: *Self, item: T) !void {
            assert(self.len <= capacity); // Length must be valid
            if (self.len >= capacity) return error.Overflow;

            self.items[self.len] = item;
            self.len += 1;

            assert(self.len <= capacity); // Verify length is still valid
        }

        pub fn pop(self: *Self) ?T {
            assert(self.len <= capacity); // Length must be valid
            if (self.len == 0) return null;

            self.len -= 1;
            const result = self.items[self.len];

            assert(self.len <= capacity); // Verify length is still valid
            return result;
        }

        pub fn slice(self: *const Self) []const T {
            assert(self.len <= capacity); // Length must be valid
            return self.items[0..self.len];
        }

        pub fn slice_mut(self: *Self) []T {
            assert(self.len <= capacity); // Length must be valid
            return self.items[0..self.len];
        }

        pub fn unused_capacity_slice(self: *Self) []T {
            assert(self.len <= capacity); // Length must be valid
            return self.items[self.len..];
        }

        pub fn resize(self: *Self, new_len: usize) !void {
            assert(self.len <= capacity); // Current length must be valid
            if (new_len > capacity) return error.Overflow;

            self.len = new_len;
            assert(self.len <= capacity); // New length must be valid
        }

        pub fn capacity_total(self: *const Self) usize {
            _ = self;
            return capacity;
        }

        pub fn capacity_remaining(self: *const Self) usize {
            assert(self.len <= capacity); // Length must be valid
            return capacity - self.len;
        }

        pub fn is_full(self: *const Self) bool {
            assert(self.len <= capacity); // Length must be valid
            return self.len == capacity;
        }

        pub fn is_empty(self: *const Self) bool {
            assert(self.len <= capacity); // Length must be valid
            return self.len == 0;
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }
    };
}

/// ProxyConnection - Represents an active client-to-backend proxy connection
pub const ProxyConnection = struct {
    client: net.Stream,
    backend: net.Stream,
    state: State,

    const State = enum {
        connecting,
        active,
        closing,
    };
};

test "BoundedArray: basic operations" {
    var arr = BoundedArray(u32, 4).init();

    // Initially empty
    try std.testing.expect(arr.is_empty());
    try std.testing.expect(!arr.is_full());
    try std.testing.expectEqual(@as(usize, 0), arr.len);
    try std.testing.expectEqual(@as(usize, 4), arr.capacity_remaining());

    // Push items
    try arr.push(10);
    try arr.push(20);
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expect(!arr.is_empty());
    try std.testing.expect(!arr.is_full());

    // Access via slice
    const s = arr.slice();
    try std.testing.expectEqual(@as(u32, 10), s[0]);
    try std.testing.expectEqual(@as(u32, 20), s[1]);

    // Fill to capacity
    try arr.push(30);
    try arr.push(40);
    try std.testing.expect(arr.is_full());
    try std.testing.expectEqual(@as(usize, 0), arr.capacity_remaining());

    // Overflow
    try std.testing.expectError(error.Overflow, arr.push(50));

    // Pop
    try std.testing.expectEqual(@as(?u32, 40), arr.pop());
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expect(!arr.is_full());

    // Clear
    arr.clear();
    try std.testing.expect(arr.is_empty());
    try std.testing.expectEqual(@as(usize, 0), arr.len);
}
