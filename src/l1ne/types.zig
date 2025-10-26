const std = @import("std");
const assert = std.debug.assert;
// const net = std.net;

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
