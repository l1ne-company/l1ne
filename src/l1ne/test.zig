//! L1NE Test Suite
//!
//! This file imports all L1NE unit tests for execution via `zig build test`.
//!
//! Test modules:
//!   - iops_test.zig: IOPSType and BitSet tests
//!   - static_allocator_test.zig: StaticAllocator tests
//!   - config_test.zig: Config and Nix parsing tests
//!
//! Run with: zig build test

const std = @import("std");

// Import all test modules
// The _ = syntax tells Zig to include these modules' tests in the test suite
test {
    std.testing.refAllDecls(@This());
}

// IOPSType and BitSet comprehensive tests
comptime {
    _ = @import("iops_test.zig");
}

// StaticAllocator two-phase allocation tests
comptime {
    _ = @import("static_allocator_test.zig");
}

// Config and Nix parsing tests
comptime {
    _ = @import("config_test.zig");
}

// WAL (Write-Ahead Log) tests
comptime {
    _ = @import("wal_test.zig");
}

// Simulator and time abstraction tests
comptime {
    _ = @import("simulator_test.zig");
}

// Transaction system tests
comptime {
    _ = @import("transaction_test.zig");
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
