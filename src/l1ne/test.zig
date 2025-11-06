//! L1NE Test Suite
//!
//! This file imports all L1NE unit tests for execution via `zig build test`.
//!
//!
//! Run with: `zig build test`. The combined suite lives in `tests.zig`;
//! add new cases there and they will be picked up automatically.

const std = @import("std");

// Import all test modules
// The _ = syntax tells Zig to include these modules' tests in the test suite
test {
    std.testing.refAllDecls(@This());
}

// Combined test suite (replaces previous individual *_test files)
comptime {
    _ = @import("tests.zig");
}

// Also include inline tests from main modules
comptime {
    _ = @import("iops.zig");
    _ = @import("static_allocator.zig");
    _ = @import("config.zig");
    _ = @import("wal.zig");
    _ = @import("time.zig");
    _ = @import("simulator.zig");
    _ = @import("service_registry.zig");
    _ = @import("prng.zig");
    _ = @import("fault_injector.zig");
    _ = @import("scenario.zig");
    _ = @import("scenario_config.zig");
    _ = @import("verification.zig");
    _ = @import("metrics.zig");
}
