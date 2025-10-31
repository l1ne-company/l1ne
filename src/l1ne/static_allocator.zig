//! Static Allocator - Two-phase memory allocation for L1NE
//!
//! This allocator enforces NASA-style static memory allocation:
//!
//! Phase 1 (INIT): Dynamic allocation allowed to build initial state
//! Phase 2 (STATIC): No allocation allowed - system runs with bounded memory forever
//!
//! The transition from INIT → STATIC is one-way and irreversible. Any attempt to
//! allocate in STATIC mode will panic. This guarantees zero allocation after startup.
//!
//! Usage:
//!   var static_alloc = StaticAllocator.init(page_allocator);
//!   const allocator = static_alloc.allocator();
//!
//!   // Phase 1: Allocate everything needed
//!   var data = try allocator.alloc(u8, 1024);
//!
//!   // Phase 2: Lock allocator - no more allocation
//!   static_alloc.transition_to_static();
//!
//!   // This would panic: allocator.alloc(u8, 100)

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const StaticAllocator = struct {
    state: State,
    backing_allocator: Allocator,
    total_allocated: u64, // Track total allocation for diagnostics

    pub const State = enum {
        init, // Dynamic allocation allowed
        static, // No allocation allowed - system is locked
    };

    /// Initialize allocator in INIT state
    ///
    /// Invariants:
    ///   - Post: state == .init
    ///   - Post: total_allocated == 0
    ///   - Does not allocate memory
    pub fn init(backing_allocator: Allocator) StaticAllocator {
        // Backing allocator must have valid vtable
        assert(@intFromPtr(backing_allocator.ptr) != 0);
        assert(@intFromPtr(backing_allocator.vtable) != 0);

        const result = StaticAllocator{
            .state = .init,
            .backing_allocator = backing_allocator,
            .total_allocated = 0,
        };

        assert(result.state == .init);
        assert(result.total_allocated == 0);

        return result;
    }

    /// Transition from INIT → STATIC (one-way, irreversible)
    /// After this call, any allocation attempt will panic
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: state == .init (can only transition once)
    ///   - Pre: total_allocated > 0 (must have allocated something)
    ///   - Post: state == .static
    ///   - This transition is permanent and cannot be reversed
    pub fn transition_to_static(self: *StaticAllocator) void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(self.state == .init); // Can only transition from init
        assert(self.total_allocated > 0); // Must have allocated something

        const old_state = self.state;
        self.state = .static;

        assert(old_state == .init); // Verify old state
        assert(self.state == .static); // Verify new state
        assert(self.is_static()); // Verify consistent query

        std.log.info("=== STATIC ALLOCATION LOCKED ===", .{});
        std.log.info("Total allocated: {d:.2} MiB", .{
            @as(f64, @floatFromInt(self.total_allocated)) / (1024.0 * 1024.0),
        });
        std.log.info("No further allocation allowed", .{});
        std.log.info("================================", .{});
    }

    /// Get an Allocator interface for this StaticAllocator
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: returned Allocator is valid
    ///   - Does not allocate memory
    pub fn allocator(self: *StaticAllocator) Allocator {
        assert(@intFromPtr(self) != 0); // Self must be valid

        const result = Allocator{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = Allocator.noRemap,
            },
        };

        assert(@intFromPtr(result.ptr) != 0); // Result ptr must be valid
        assert(@intFromPtr(result.vtable) != 0); // Result vtable must be valid

        return result;
    }

    /// Helper: Report allocation attempt in STATIC mode and panic
    fn panicStaticAlloc(operation: []const u8, size: usize, alignment: std.mem.Alignment, ret_addr: usize) noreturn {
        assert(operation.len > 0); // Operation name must not be empty
        assert(size > 0); // Size must be non-zero

        std.log.err("FATAL: Attempted {s} in STATIC mode!", .{operation});
        std.log.err("  Size: {d} bytes", .{size});
        std.log.err("  Alignment: {d}", .{@intFromEnum(alignment)});
        std.log.err("  Return address: 0x{x}", .{ret_addr});
        std.log.err("", .{});
        std.log.err("This is a programming error. The allocator was locked after", .{});
        std.log.err("initialization to guarantee bounded memory usage. All memory", .{});
        std.log.err("must be allocated during INIT phase before transition_to_static().", .{});

        @panic("Memory operation attempted after transition to static mode");
    }

    /// Helper: Update total allocated counter after successful allocation
    fn updateAllocated(self: *StaticAllocator, delta: i64) void {
        assert(@intFromPtr(self) != 0); // Self must be valid

        if (delta > 0) {
            // Allocation or growth
            self.total_allocated += @intCast(delta);
        } else if (delta < 0) {
            // Deallocation or shrinkage
            const abs_delta: u64 = @intCast(-delta);
            if (self.total_allocated >= abs_delta) {
                self.total_allocated -= abs_delta;
            } else {
                // Accounting underflow - shouldn't happen but guard against it
                std.log.warn("Allocation accounting underflow: {d} < {d}", .{ self.total_allocated, abs_delta });
                self.total_allocated = 0;
            }
        }
        // delta == 0: no change
    }

    /// Allocate memory (only allowed in INIT state)
    ///
    /// Invariants:
    ///   - Pre: ctx points to valid StaticAllocator
    ///   - Pre: len > 0 (must allocate non-zero size)
    ///   - Pre: ptr_align is valid alignment
    ///   - If state == .static: panics (programming error)
    ///   - If state == .init: forwards to backing allocator
    ///   - Post: if successful, total_allocated increases by len
    ///   - Post: returned pointer is aligned to ptr_align
    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *StaticAllocator = @ptrCast(@alignCast(ctx));
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(len > 0); // Must allocate non-zero size

        // CRITICAL: Panic if trying to allocate in STATIC mode
        if (self.state == .static) {
            panicStaticAlloc("allocation", len, ptr_align, ret_addr);
        }

        assert(self.state == .init); // Must be in init state

        const old_allocated = self.total_allocated;

        // Forward to backing allocator
        const result = self.backing_allocator.rawAlloc(len, ptr_align, ret_addr);

        if (result) |ptr| {
            assert(@intFromPtr(ptr) != 0); // Result must be valid

            // ptr_align is log2 of alignment, convert to actual alignment
            const alignment = @as(usize, 1) << @intFromEnum(ptr_align);
            assert(@intFromPtr(ptr) % alignment == 0); // Must be properly aligned

            self.updateAllocated(@intCast(len));
            assert(self.total_allocated == old_allocated + len); // Accounting correct
        }

        return result;
    }

    /// Resize allocation (only allowed in INIT state)
    ///
    /// Invariants:
    ///   - Pre: ctx points to valid StaticAllocator
    ///   - Pre: buf.len > 0 (buffer must be non-empty)
    ///   - Pre: buf.ptr is valid and aligned
    ///   - If state == .static: panics (programming error)
    ///   - If state == .init: forwards to backing allocator
    ///   - Post: if successful and growing, total_allocated increases by delta
    ///   - Post: if successful and shrinking, total_allocated decreases by delta
    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *StaticAllocator = @ptrCast(@alignCast(ctx));
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(buf.len > 0); // Buffer must be non-empty
        assert(@intFromPtr(buf.ptr) != 0); // Buffer must be valid
        assert(@intFromPtr(buf.ptr) % @intFromEnum(buf_align) == 0); // Must be properly aligned

        // CRITICAL: Panic if trying to resize in STATIC mode
        if (self.state == .static) {
            panicStaticAlloc("resize", new_len, buf_align, ret_addr);
        }

        assert(self.state == .init); // Must be in init state

        const old_allocated = self.total_allocated;
        const old_len = buf.len;

        // Forward to backing allocator
        const result = self.backing_allocator.rawResize(buf, buf_align, new_len, ret_addr);

        if (result) {
            // Update total allocated count based on size change
            const delta: i64 = @as(i64, @intCast(new_len)) - @as(i64, @intCast(old_len));
            self.updateAllocated(delta);

            // Verify accounting is correct
            if (new_len > old_len) {
                assert(self.total_allocated == old_allocated + (new_len - old_len));
            } else if (new_len < old_len) {
                assert(self.total_allocated == old_allocated - (old_len - new_len));
            } else {
                assert(self.total_allocated == old_allocated); // No change
            }
        }

        return result;
    }

    /// Free memory (allowed in both states)
    /// Note: In STATIC mode, we typically never free - memory is reused via IOPs pools
    ///
    /// Invariants:
    ///   - Pre: ctx points to valid StaticAllocator
    ///   - Pre: buf.len > 0 (buffer must be non-empty)
    ///   - Pre: buf.ptr is valid and aligned
    ///   - Allowed in both INIT and STATIC states
    ///   - Post: total_allocated decreases by buf.len (or goes to 0 on underflow)
    ///   - Logs warning if called in STATIC mode (unusual but valid)
    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *StaticAllocator = @ptrCast(@alignCast(ctx));
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(buf.len > 0); // Buffer must be non-empty
        assert(@intFromPtr(buf.ptr) != 0); // Buffer must be valid

        // buf_align is log2 of alignment, convert to actual alignment
        const alignment = @as(usize, 1) << @intFromEnum(buf_align);
        assert(@intFromPtr(buf.ptr) % alignment == 0); // Must be properly aligned

        const old_allocated = self.total_allocated;

        // Log warning if freeing in STATIC mode (unusual but allowed)
        if (self.state == .static) {
            std.log.warn("Free called in STATIC mode (size: {d} bytes)", .{buf.len});
            std.log.warn("  This is unusual - STATIC mode should use IOPs pools", .{});
        }

        // Forward to backing allocator
        self.backing_allocator.rawFree(buf, buf_align, ret_addr);

        // Update total allocated count
        self.updateAllocated(-@as(i64, @intCast(buf.len)));

        // Verify accounting (allowing for underflow to 0)
        if (old_allocated >= buf.len) {
            assert(self.total_allocated == old_allocated - buf.len);
        } else {
            assert(self.total_allocated == 0); // Underflow clamped to 0
        }
    }

    /// Get current state
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: result is either .init or .static
    ///   - Does not modify state
    pub fn get_state(self: *const StaticAllocator) State {
        assert(@intFromPtr(self) != 0); // Self must be valid
        const result = self.state;
        assert(result == .init or result == .static); // Must be valid state
        return result;
    }

    /// Check if allocator is in STATIC mode
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: result == (state == .static)
    ///   - Does not modify state
    pub fn is_static(self: *const StaticAllocator) bool {
        assert(@intFromPtr(self) != 0); // Self must be valid
        const result = self.state == .static;
        assert(result == (self.get_state() == .static)); // Consistent definition
        return result;
    }

    /// Get total allocated memory
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: result >= 0
    ///   - Does not modify state
    pub fn get_total_allocated(self: *const StaticAllocator) u64 {
        assert(@intFromPtr(self) != 0); // Self must be valid
        return self.total_allocated;
    }
};

test "StaticAllocator: basic allocation in INIT state" {
    var static_alloc = StaticAllocator.init(std.testing.allocator);
    const allocator = static_alloc.allocator();

    // Should be able to allocate in INIT state
    const buf = try allocator.alloc(u8, 1024);
    defer allocator.free(buf);

    try std.testing.expectEqual(@as(usize, 1024), buf.len);
    try std.testing.expect(static_alloc.get_total_allocated() >= 1024);
    try std.testing.expectEqual(StaticAllocator.State.init, static_alloc.get_state());
    try std.testing.expect(!static_alloc.is_static());
}

test "StaticAllocator: transition to STATIC prevents allocation" {
    var static_alloc = StaticAllocator.init(std.testing.allocator);
    const allocator = static_alloc.allocator();

    // Allocate something in INIT state
    const buf1 = try allocator.alloc(u8, 512);
    defer allocator.free(buf1);

    // Transition to STATIC
    static_alloc.transition_to_static();
    try std.testing.expect(static_alloc.is_static());

    // Note: We can't actually test that allocation panics in STATIC mode
    // because that would crash the test. In real usage, attempting to
    // allocate in STATIC mode will panic with a clear error message.
}

test "StaticAllocator: tracks total allocated memory" {
    var static_alloc = StaticAllocator.init(std.testing.allocator);
    const allocator = static_alloc.allocator();

    try std.testing.expectEqual(@as(u64, 0), static_alloc.get_total_allocated());

    const buf1 = try allocator.alloc(u8, 1024);
    try std.testing.expect(static_alloc.get_total_allocated() >= 1024);

    const buf2 = try allocator.alloc(u8, 2048);
    try std.testing.expect(static_alloc.get_total_allocated() >= 3072);

    allocator.free(buf1);
    try std.testing.expect(static_alloc.get_total_allocated() >= 2048);

    allocator.free(buf2);
    // After freeing everything, should be back to ~0 (may have small overhead)
    try std.testing.expect(static_alloc.get_total_allocated() < 100);
}
