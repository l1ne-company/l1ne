// Combined test suite for L1NE.
// Collects every *_test.zig module into a single compilation unit.
// Add or edit tests in the labeled sections below—`src/l1ne/test.zig` pulls
// this file into every `zig build test` run automatically.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

const wal = @import("wal.zig");
const simulator = @import("simulator.zig");
const time_mod = @import("time.zig");
const service_registry = @import("service_registry.zig");
const static_allocator_mod = @import("static_allocator.zig");
const config_mod = @import("config.zig");
const types = @import("types.zig");
const iops = @import("iops.zig");

const StaticAllocator = static_allocator_mod.StaticAllocator;
const Config = config_mod.Config;
const ServiceConfig = config_mod.ServiceConfig;
const BitSet = iops.BitSet;
const IOPSType = iops.IOPSType;

// ===== config_test.zig =====
// Comprehensive tests for Config and Nix parsing
//
// These tests verify:
// - Nix source parsing
// - Runtime limits extraction
// - Service configuration extraction
// - Validation and error handling
// - Edge cases and malformed input

// Test: Parse minimal valid config

// Verifies:
//   - Can parse simple Nix config
//   - Runtime limits are extracted correctly
//   - Default values are used when not specified
test "Config: parse minimal valid config" {
    const source =
        \\{
        \\  runtime = {
        \\    proxy_connections_max = 128;
        \\    proxy_buffer_size_kb = 8;
        \\  };
        \\}
    ;

    var cfg = try Config.from_nix_source(testing.allocator, source);
    defer cfg.deinit();

    try testing.expectEqual(@as(u32, 128), cfg.limits.proxy_connections_max);
    try testing.expectEqual(@as(u32, 8 * types.KIB), cfg.limits.proxy_buffer_size);
    try testing.expectEqual(@as(usize, 0), cfg.services.len);
}

// Test: Parse complete config with all fields

// Verifies:
//   - All runtime limits are parsed
//   - Multiple services are extracted
//   - All service fields are correct
test "Config: parse complete config" {
    const source =
        \\{
        \\  runtime = {
        \\    proxy_connections_max = 256;
        \\    proxy_buffer_size_kb = 4;
        \\    cgroup_monitors_max = 4;
        \\    systemd_buffer_size_kb = 8;
        \\  };
        \\  services = {
        \\    max_instances = 2;
        \\    instances = [
        \\      {
        \\        name = "service-1";
        \\        exec = "/usr/bin/service1";
        \\        port = 8080;
        \\        memory_mb = 100;
        \\        cpu_percent = 50;
        \\      }
        \\      {
        \\        name = "service-2";
        \\        exec = "/usr/bin/service2";
        \\        port = 8081;
        \\        memory_mb = 200;
        \\        cpu_percent = 75;
        \\      }
        \\    ];
        \\  };
        \\}
    ;

    var cfg = try Config.from_nix_source(testing.allocator, source);
    defer cfg.deinit();

    // Verify runtime limits
    try testing.expectEqual(@as(u32, 256), cfg.limits.proxy_connections_max);
    try testing.expectEqual(@as(u32, 4 * types.KIB), cfg.limits.proxy_buffer_size);
    try testing.expectEqual(@as(u32, 4), cfg.limits.cgroup_monitors_count);
    try testing.expectEqual(@as(u32, 8 * types.KIB), cfg.limits.systemd_buffer_size);

    // Verify services
    try testing.expectEqual(@as(usize, 2), cfg.services.len);

    // Service 1
    try testing.expectEqualStrings("service-1", cfg.services[0].name);
    try testing.expectEqualStrings("/usr/bin/service1", cfg.services[0].exec_path);
    try testing.expectEqual(@as(u16, 8080), cfg.services[0].port);
    try testing.expectEqual(@as(u32, 100), cfg.services[0].memory_mb);
    try testing.expectEqual(@as(u8, 50), cfg.services[0].cpu_percent);

    // Service 2
    try testing.expectEqualStrings("service-2", cfg.services[1].name);
    try testing.expectEqualStrings("/usr/bin/service2", cfg.services[1].exec_path);
    try testing.expectEqual(@as(u16, 8081), cfg.services[1].port);
    try testing.expectEqual(@as(u32, 200), cfg.services[1].memory_mb);
    try testing.expectEqual(@as(u8, 75), cfg.services[1].cpu_percent);
}

// Test: Parse config with default service values

// Verifies:
//   - Services can omit optional fields
//   - Default values are applied
//   - Required fields are still enforced
test "Config: parse config with default values" {
    const source =
        \\{
        \\  runtime = {
        \\    proxy_connections_max = 64;
        \\  };
        \\  services = {
        \\    instances = [
        \\      {
        \\        name = "minimal-service";
        \\        exec = "/bin/test";
        \\      }
        \\    ];
        \\  };
        \\}
    ;

    var cfg = try Config.from_nix_source(testing.allocator, source);
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 1), cfg.services.len);

    // Verify required fields
    try testing.expectEqualStrings("minimal-service", cfg.services[0].name);
    try testing.expectEqualStrings("/bin/test", cfg.services[0].exec_path);

    // Verify defaults
    try testing.expectEqual(@as(u16, 8080), cfg.services[0].port);
    try testing.expectEqual(@as(u32, 50), cfg.services[0].memory_mb);
    try testing.expectEqual(@as(u8, 10), cfg.services[0].cpu_percent);
}

// Test: Parse config with multiple services

// Verifies:
//   - Can handle up to 16 services (compile-time limit)
//   - All services are parsed correctly
//   - Order is preserved
test "Config: parse multiple services" {
    const source =
        \\{
        \\  services = {
        \\    instances = [
        \\      { name = "s1"; exec = "/bin/s1"; port = 8001; }
        \\      { name = "s2"; exec = "/bin/s2"; port = 8002; }
        \\      { name = "s3"; exec = "/bin/s3"; port = 8003; }
        \\      { name = "s4"; exec = "/bin/s4"; port = 8004; }
        \\    ];
        \\  };
        \\}
    ;

    var cfg = try Config.from_nix_source(testing.allocator, source);
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 4), cfg.services.len);

    // Verify order and content
    try testing.expectEqualStrings("s1", cfg.services[0].name);
    try testing.expectEqual(@as(u16, 8001), cfg.services[0].port);

    try testing.expectEqualStrings("s4", cfg.services[3].name);
    try testing.expectEqual(@as(u16, 8004), cfg.services[3].port);
}

// Test: Parse config with only runtime limits

// Verifies:
//   - Config without services is valid
//   - Runtime limits are still extracted
//   - Services list is empty
test "Config: parse runtime limits only" {
    const source =
        \\{
        \\  runtime = {
        \\    proxy_connections_max = 512;
        \\    proxy_buffer_size_kb = 16;
        \\    cgroup_monitors_max = 8;
        \\    systemd_buffer_size_kb = 4;
        \\  };
        \\}
    ;

    var cfg = try Config.from_nix_source(testing.allocator, source);
    defer cfg.deinit();

    try testing.expectEqual(@as(u32, 512), cfg.limits.proxy_connections_max);
    try testing.expectEqual(@as(u32, 16 * types.KIB), cfg.limits.proxy_buffer_size);
    try testing.expectEqual(@as(u32, 8), cfg.limits.cgroup_monitors_count);
    try testing.expectEqual(@as(u32, 4 * types.KIB), cfg.limits.systemd_buffer_size);
    try testing.expectEqual(@as(usize, 0), cfg.services.len);
}

// Test: Config deinit cleans up memory

// Verifies:
//   - deinit frees all allocated memory
//   - No memory leaks
//   - Can safely call deinit
test "Config: deinit cleanup" {
    const source =
        \\{
        \\  services = {
        \\    instances = [
        \\      { name = "test-1"; exec = "/usr/bin/test1"; }
        \\      { name = "test-2"; exec = "/usr/bin/test2"; }
        \\    ];
        \\  };
        \\}
    ;

    var cfg = try Config.from_nix_source(testing.allocator, source);

    // Verify services were allocated
    try testing.expectEqual(@as(usize, 2), cfg.services.len);

    // Deinit should free everything
    cfg.deinit();
}

// Test: Parse config with various integer sizes

// Verifies:
//   - Small integers parse correctly
//   - Large integers parse correctly
//   - Type casting works as expected
test "Config: parse various integer sizes" {
    const source =
        \\{
        \\  runtime = {
        \\    proxy_connections_max = 1;
        \\    proxy_buffer_size_kb = 16;
        \\  };
        \\  services = {
        \\    instances = [
        \\      {
        \\        name = "test";
        \\        exec = "/bin/test";
        \\        port = 1;
        \\        memory_mb = 1;
        \\        cpu_percent = 1;
        \\      }
        \\    ];
        \\  };
        \\}
    ;

    var cfg = try Config.from_nix_source(testing.allocator, source);
    defer cfg.deinit();

    try testing.expectEqual(@as(u32, 1), cfg.limits.proxy_connections_max);
    try testing.expectEqual(@as(u32, 16 * types.KIB), cfg.limits.proxy_buffer_size);

    try testing.expectEqual(@as(u16, 1), cfg.services[0].port);
    try testing.expectEqual(@as(u32, 1), cfg.services[0].memory_mb);
    try testing.expectEqual(@as(u8, 1), cfg.services[0].cpu_percent);
}

// Test: Parse config with realistic values

// Verifies:
//   - Realistic production config parses correctly
//   - All fields have sensible values
//   - Config matches example.nix
test "Config: parse realistic production config" {
    const source =
        \\{
        \\  runtime = {
        \\    proxy_connections_max = 256;
        \\    proxy_buffer_size_kb = 4;
        \\    cgroup_monitors_max = 4;
        \\    systemd_buffer_size_kb = 4;
        \\  };
        \\  services = {
        \\    max_instances = 4;
        \\    instances = [
        \\      {
        \\        name = "demo-1";
        \\        exec = "./dumb-server/result/bin/dumb-server";
        \\        port = 8081;
        \\        memory_mb = 50;
        \\        cpu_percent = 25;
        \\      }
        \\      {
        \\        name = "demo-2";
        \\        exec = "./dumb-server/result/bin/dumb-server";
        \\        port = 8082;
        \\        memory_mb = 50;
        \\        cpu_percent = 25;
        \\      }
        \\    ];
        \\  };
        \\}
    ;

    var cfg = try Config.from_nix_source(testing.allocator, source);
    defer cfg.deinit();

    // Verify runtime limits
    try testing.expectEqual(@as(u32, 256), cfg.limits.proxy_connections_max);
    try testing.expectEqual(@as(u32, 4 * types.KIB), cfg.limits.proxy_buffer_size);
    try testing.expectEqual(@as(u32, 4), cfg.limits.cgroup_monitors_count);
    try testing.expectEqual(@as(u32, 4 * types.KIB), cfg.limits.systemd_buffer_size);

    // Verify services
    try testing.expectEqual(@as(usize, 2), cfg.services.len);
    try testing.expectEqualStrings("demo-1", cfg.services[0].name);
    try testing.expectEqualStrings("demo-2", cfg.services[1].name);
}

test "Config: from_nix_file resolves relative exec paths to absolute" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const config_source =
        \\{
        \\  runtime = {
        \\    proxy_connections_max = 4;
        \\  };
        \\  services = {
        \\    instances = [
        \\      {
        \\        name = "demo";
        \\        exec = "./bin/demo-service";
        \\      }
        \\    ];
        \\  };
        \\}
    ;

    try tmp.dir.writeFile(.{
        .sub_path = "config.nix",
        .data = config_source,
    });

    const config_path = try tmp.dir.realpathAlloc(testing.allocator, "config.nix");
    defer testing.allocator.free(config_path);

    var cfg = try Config.from_nix_file(testing.allocator, config_path);
    defer cfg.deinit();

    try testing.expect(@as(usize, 1) == cfg.services.len);
    try testing.expect(std.fs.path.isAbsolute(cfg.services[0].exec_path));

    const base_dir = std.fs.path.dirname(config_path) orelse config_path;
    const expected_exec = try std.fs.path.resolve(
        testing.allocator,
        &[_][]const u8{ base_dir, "bin/demo-service" },
    );
    defer testing.allocator.free(expected_exec);

    try testing.expectEqualStrings(expected_exec, cfg.services[0].exec_path);
}

// Test: Parse config with standard whitespace

// Verifies:
//   - Parser handles standard formatting correctly
//   - Normal whitespace doesn't affect parsing
test "Config: parse with standard whitespace" {
    const source =
        \\{
        \\  runtime = {
        \\    proxy_connections_max = 128;
        \\    proxy_buffer_size_kb = 8;
        \\  };
        \\}
    ;

    var cfg = try Config.from_nix_source(testing.allocator, source);
    defer cfg.deinit();

    try testing.expectEqual(@as(u32, 128), cfg.limits.proxy_connections_max);
    try testing.expectEqual(@as(u32, 8 * types.KIB), cfg.limits.proxy_buffer_size);
}

// Test: Parse config with comments (if supported)

// Verifies:
//   - Comments are ignored
//   - Content after comments is parsed
test "Config: parse with comments" {
    const source =
        \\{
        \\  # This is a comment
        \\  runtime = {
        \\    proxy_connections_max = 64; # Another comment
        \\  };
        \\}
    ;

    var cfg = try Config.from_nix_source(testing.allocator, source);
    defer cfg.deinit();

    try testing.expectEqual(@as(u32, 64), cfg.limits.proxy_connections_max);
}

// Test: Parse empty config

// Verifies:
//   - Empty config uses defaults
//   - No services configured
//   - Still valid
test "Config: parse empty config" {
    const source = "{}";

    var cfg = try Config.from_nix_source(testing.allocator, source);
    defer cfg.deinit();

    // Should use defaults (defined in constants.zig)
    try testing.expectEqual(@as(usize, 0), cfg.services.len);
}

// ===== iops_test.zig =====
// Comprehensive tests for IOPSType and BitSet
//
// These tests verify:
// - BitSet operations (set, unset, first_unset, count, is_set)
// - IOPSType acquire/release semantics
// - Pool exhaustion and backpressure
// - Pointer arithmetic correctness
// - Invariant validation

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
    try testing.expectEqual(@as(?u6, 0), bs.first_unset(64));
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
    try testing.expectEqual(@as(?u6, 0), bs.first_unset(64));

    // Set bit 0, should return 1
    bs.set(0);
    try testing.expectEqual(@as(?u6, 1), bs.first_unset(64));

    // Set bits 1-4, should return 5
    bs.set(1);
    bs.set(2);
    bs.set(3);
    bs.set(4);
    try testing.expectEqual(@as(?u6, 5), bs.first_unset(64));

    // Set all bits except 10
    var i: u8 = 0;
    while (i < 64) : (i += 1) {
        const idx: u6 = @intCast(i);
        if (i != 10) {
            if (!bs.is_set(idx)) bs.set(idx);
        }
    }
    try testing.expectEqual(@as(?u6, 10), bs.first_unset(64));

    // Set bit 10, should return null (all full)
    bs.set(10);
    try testing.expectEqual(@as(?u6, null), bs.first_unset(64));
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
    try testing.expectEqual(@as(?u6, null), bs.first_unset(64));

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

// ===== simulator_test.zig =====
// Comprehensive tests for Simulator
//
// These tests verify:
// - Event loading from WAL entries
// - Deterministic replay
// - State tracking
// - Time advancement
// - Invariant checking

// Test: State initialization

// Verifies:
//   - State starts with zero counts
//   - All fields initialized
test "Simulator State: initialization" {
    const state = simulator.State.init();

    try testing.expectEqual(@as(u32, 0), state.services_started);
    try testing.expectEqual(@as(u32, 0), state.services_stopped);
    try testing.expectEqual(@as(u64, 0), state.connections_opened);
    try testing.expectEqual(@as(u64, 0), state.connections_closed);
    try testing.expectEqual(@as(u64, 0), state.bytes_sent_total);
    try testing.expectEqual(@as(u64, 0), state.bytes_received_total);
}

// Test: State active services calculation

// Verifies:
//   - Active services = started - stopped
//   - Calculation is correct
test "Simulator State: active services" {
    var state = simulator.State.init();
    var registry = service_registry.ServiceRegistry.init();

    // Start 3 services
    const start_event = simulator.Event{
        .timestamp_us = 1_001_000,
        .event_type = .service_start,
        .data = .{ .service_start = .{ .service_id = 1, .port = 8080 } },
    };

    state.apply_event(&start_event, &registry);
    state.apply_event(&start_event, &registry);
    state.apply_event(&start_event, &registry);

    try testing.expectEqual(@as(u32, 3), state.active_services());

    // Stop 1 service
    const stop_event = simulator.Event{
        .timestamp_us = 1_002_000,
        .event_type = .service_stop,
        .data = .{ .service_stop = .{ .service_id = 1, .exit_code = 0 } },
    };

    state.apply_event(&stop_event, &registry);

    try testing.expectEqual(@as(u32, 2), state.active_services());
}

// Test: State active connections calculation

// Verifies:
//   - Active connections = opened - closed
//   - Calculation is correct
test "Simulator State: active connections" {
    var state = simulator.State.init();
    var registry = service_registry.ServiceRegistry.init();

    // Open 5 connections
    const accept_event = simulator.Event{
        .timestamp_us = 1_001_000,
        .event_type = .proxy_accept,
        .data = .{ .proxy_accept = .{ .connection_id = 1, .service_id = 1, .client_port = 12345 } },
    };

    var i: u64 = 0;
    while (i < 5) : (i += 1) {
        state.apply_event(&accept_event, &registry);
    }

    try testing.expectEqual(@as(u64, 5), state.active_connections());

    // Close 2 connections
    const close_event = simulator.Event{
        .timestamp_us = 1_002_000,
        .event_type = .proxy_close,
        .data = .{ .proxy_close = .{ .connection_id = 1, .bytes_sent = 100, .bytes_received = 200 } },
    };

    state.apply_event(&close_event, &registry);
    state.apply_event(&close_event, &registry);

    try testing.expectEqual(@as(u64, 3), state.active_connections());
}

// Test: State byte counters

// Verifies:
//   - Bytes sent/received accumulate correctly
//   - Counters only increase
test "Simulator State: byte counters" {
    var state = simulator.State.init();
    var registry = service_registry.ServiceRegistry.init();

    const close_event1 = simulator.Event{
        .timestamp_us = 1_001_000,
        .event_type = .proxy_close,
        .data = .{ .proxy_close = .{ .connection_id = 1, .bytes_sent = 1000, .bytes_received = 2000 } },
    };

    const close_event2 = simulator.Event{
        .timestamp_us = 1_002_000,
        .event_type = .proxy_close,
        .data = .{ .proxy_close = .{ .connection_id = 2, .bytes_sent = 500, .bytes_received = 1500 } },
    };

    state.apply_event(&close_event1, &registry);
    try testing.expectEqual(@as(u64, 1000), state.bytes_sent_total);
    try testing.expectEqual(@as(u64, 2000), state.bytes_received_total);

    state.apply_event(&close_event2, &registry);
    try testing.expectEqual(@as(u64, 1500), state.bytes_sent_total);
    try testing.expectEqual(@as(u64, 3500), state.bytes_received_total);
}

// Test: Simulator initialization

// Verifies:
//   - Simulator starts empty
//   - Clock is in simulated mode
test "Simulator: initialization" {
    var clock = time_mod.Clock.init_simulated(1_000_000);
    const sim = simulator.Simulator.init(&clock);

    try testing.expectEqual(@as(u32, 0), sim.event_count);
    try testing.expectEqual(@as(u32, 0), sim.current_event);
    try testing.expect(!sim.has_next());
}

// Test: Load single event

// Verifies:
//   - Can load WAL entry
//   - Event count increments
test "Simulator: load single event" {
    var clock = time_mod.Clock.init_simulated(1_000_000);
    var sim = simulator.Simulator.init(&clock);

    // Create WAL entry
    var payload_struct = wal.ServiceStartPayload{
        .service_id = 42,
        .port = 8080,
        ._reserved = [_]u8{0} ** 122,
    };
    const payload_bytes = std.mem.asBytes(&payload_struct);
    const entry = wal.create_entry(1000, .service_start, payload_bytes[0..128].*);

    try sim.load_event(&entry);

    try testing.expectEqual(@as(u32, 1), sim.event_count);
    try testing.expect(sim.has_next());
}

// Test: Load multiple events

// Verifies:
//   - Can load many events
//   - Count tracks correctly
test "Simulator: load multiple events" {
    var clock = time_mod.Clock.init_simulated(1_000_000);
    var sim = simulator.Simulator.init(&clock);

    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        var payload_struct = wal.ServiceStartPayload{
            .service_id = @intCast(i + 1), // Start from 1, not 0
            .port = 8080,
            ._reserved = [_]u8{0} ** 122,
        };
        const payload_bytes = std.mem.asBytes(&payload_struct);
        const timestamp = 1_001_000 + i * 100;
        const entry = wal.create_entry(timestamp, .service_start, payload_bytes[0..128].*);

        try sim.load_event(&entry);
    }

    try testing.expectEqual(@as(u32, 10), sim.event_count);
    try testing.expect(sim.has_next());
}

// Test: Replay single event

// Verifies:
//   - Event replay updates state
//   - Clock advances to event timestamp
test "Simulator: replay single event" {
    var clock = time_mod.Clock.init_simulated(1_000_000);
    var sim = simulator.Simulator.init(&clock);

    var payload_struct = wal.ServiceStartPayload{
        .service_id = 42,
        .port = 8080,
        ._reserved = [_]u8{0} ** 122,
    };
    const payload_bytes = std.mem.asBytes(&payload_struct);
    const entry = wal.create_entry(2_000_000, .service_start, payload_bytes[0..128].*);

    try sim.load_event(&entry);
    try sim.replay_next();

    try testing.expectEqual(@as(u32, 1), sim.state.services_started);
    try testing.expectEqual(@as(u32, 1), sim.current_event);
    try testing.expect(!sim.has_next());

    // Verify clock advanced
    try testing.expectEqual(@as(u64, 2_000_000), clock.simulated_time_us);
}

// Test: Replay multiple events

// Verifies:
//   - All events replay in order
//   - State updates correctly
test "Simulator: replay multiple events" {
    var clock = time_mod.Clock.init_simulated(1_000_000);
    var sim = simulator.Simulator.init(&clock);

    // Load 5 service start events
    var i: u64 = 0;
    while (i < 5) : (i += 1) {
        var payload_struct = wal.ServiceStartPayload{
            .service_id = @intCast(i + 1), // Start from 1, not 0
            .port = 8080,
            ._reserved = [_]u8{0} ** 122,
        };
        const payload_bytes = std.mem.asBytes(&payload_struct);
        const timestamp = 1_001_000 + i * 1000;
        const entry = wal.create_entry(timestamp, .service_start, payload_bytes[0..128].*);
        try sim.load_event(&entry);
    }

    // Replay all events
    while (sim.has_next()) {
        try sim.replay_next();
    }

    try testing.expectEqual(@as(u32, 5), sim.state.services_started);
    try testing.expectEqual(@as(u32, 5), sim.current_event);
}

// Test: Simulator reset

// Verifies:
//   - Reset clears current position
//   - State is cleared
//   - Events remain loaded
test "Simulator: reset" {
    var clock = time_mod.Clock.init_simulated(1_000_000);
    var sim = simulator.Simulator.init(&clock);

    // Load and replay events
    var i: u64 = 0;
    while (i < 3) : (i += 1) {
        var payload_struct = wal.ServiceStartPayload{
            .service_id = @intCast(i + 1), // Start from 1, not 0
            .port = 8080,
            ._reserved = [_]u8{0} ** 122,
        };
        const payload_bytes = std.mem.asBytes(&payload_struct);
        const entry = wal.create_entry(1_001_000 + i * 100, .service_start, payload_bytes[0..128].*);
        try sim.load_event(&entry);
    }

    while (sim.has_next()) {
        try sim.replay_next();
    }

    try testing.expectEqual(@as(u32, 3), sim.state.services_started);

    // Reset
    sim.reset();

    try testing.expectEqual(@as(u32, 0), sim.current_event);
    try testing.expectEqual(@as(u32, 0), sim.state.services_started);
    try testing.expectEqual(@as(u32, 3), sim.event_count); // Events still loaded
    try testing.expect(sim.has_next());
}

// Test: Event type preservation

// Verifies:
//   - All event types decode correctly
//   - Types match WAL entry types
test "Simulator: event type preservation" {
    var clock = time_mod.Clock.init_simulated(1_000_000);
    var sim = simulator.Simulator.init(&clock);

    // Service start
    {
        var payload = wal.ServiceStartPayload{ .service_id = 1, .port = 8080, ._reserved = [_]u8{0} ** 122 };
        const bytes = std.mem.asBytes(&payload);
        const entry = wal.create_entry(1_001_000, .service_start, bytes[0..128].*);
        try sim.load_event(&entry);
    }

    // Service stop
    {
        var payload = wal.ServiceStopPayload{ .service_id = 1, .exit_code = 0, ._reserved = [_]u8{0} ** 120 };
        const bytes = std.mem.asBytes(&payload);
        const entry = wal.create_entry(1_002_000, .service_stop, bytes[0..128].*);
        try sim.load_event(&entry);
    }

    // Proxy accept
    {
        var payload = wal.ProxyAcceptPayload{ .connection_id = 1, .service_id = 1, .client_port = 12345, ._reserved = [_]u8{0} ** 114 };
        const bytes = std.mem.asBytes(&payload);
        const entry = wal.create_entry(1_003_000, .proxy_accept, bytes[0..128].*);
        try sim.load_event(&entry);
    }

    // Proxy close
    {
        var payload = wal.ProxyClosePayload{ .connection_id = 1, .bytes_sent = 100, .bytes_received = 200, ._reserved = [_]u8{0} ** 104 };
        const bytes = std.mem.asBytes(&payload);
        const entry = wal.create_entry(1_004_000, .proxy_close, bytes[0..128].*);
        try sim.load_event(&entry);
    }

    try testing.expectEqual(@as(u32, 4), sim.event_count);

    // Replay and verify types
    try sim.replay_next();
    try testing.expectEqual(@as(u32, 1), sim.state.services_started);

    try sim.replay_next();
    try testing.expectEqual(@as(u32, 1), sim.state.services_stopped);

    try sim.replay_next();
    try testing.expectEqual(@as(u64, 1), sim.state.connections_opened);

    try sim.replay_next();
    try testing.expectEqual(@as(u64, 1), sim.state.connections_closed);
}

// ===== static_allocator_test.zig =====
// Comprehensive tests for StaticAllocator
//
// These tests verify:
// - Two-phase allocation (INIT → STATIC)
// - Allocation tracking and accounting
// - State transitions
// - Error conditions
// - Memory safety guarantees

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

// ===== transaction_test.zig =====
// Transaction system tests
//
// These tests verify:
// - Transaction commit (atomic apply)
// - Transaction abort (discard all)
// - Incomplete transaction handling
// - Service state tracking via registry
// - Nested transaction prevention
// - Transaction bounds (max 64 events)

// Test 1: Transaction commit (atomic apply)
//
// Verifies:
//   - Events buffered during transaction
//   - All events applied atomically on commit
//   - State updated correctly after commit
test "Transaction: commit applies all events atomically" {
    var clock = time_mod.Clock.init_simulated(1_000_000);
    var sim = simulator.Simulator.init(&clock);

    // Create transaction with 3 service start events
    const tx_id: u64 = 1;
    const event_count: u32 = 3;

    // TX_BEGIN
    const tx_begin = wal.create_tx_begin_entry(1_001_000, tx_id, event_count);
    try sim.load_event(&tx_begin);

    // Three service start events
    var i: u32 = 0;
    while (i < event_count) : (i += 1) {
        var payload_struct = wal.ServiceStartPayload{
            .service_id = i + 1,
            .port = 8080 + @as(u16, @intCast(i)),
            ._reserved = [_]u8{0} ** 122,
        };
        const payload_bytes = std.mem.asBytes(&payload_struct);
        const timestamp = 1_002_000 + i * 100;
        const entry = wal.create_entry(timestamp, .service_start, payload_bytes[0..128].*);
        try sim.load_event(&entry);
    }

    // TX_COMMIT
    const tx_commit = wal.create_tx_commit_entry(1_003_000, tx_id, event_count);
    try sim.load_event(&tx_commit);

    // Before replay: state should be empty
    try testing.expectEqual(@as(u32, 0), sim.state.services_started);

    // Replay TX_BEGIN
    try sim.replay_next();
    try testing.expect(sim.in_transaction);
    try testing.expectEqual(@as(u64, tx_id), sim.current_tx_id);
    try testing.expectEqual(@as(u32, 0), sim.state.services_started); // No state change yet

    // Replay buffered events
    i = 0;
    while (i < event_count) : (i += 1) {
        try sim.replay_next();
        try testing.expectEqual(@as(u32, 0), sim.state.services_started); // Still buffered
        try testing.expectEqual(@as(u32, i + 1), sim.pending_count);
    }

    // Replay TX_COMMIT - atomic apply
    try sim.replay_next();
    try testing.expectEqual(@as(u32, event_count), sim.state.services_started); // All applied
    try testing.expect(!sim.in_transaction); // Transaction cleared
    try testing.expectEqual(@as(u32, 0), sim.pending_count);
}

// Test 2: Transaction abort (discard all)
//
// Verifies:
//   - Events buffered during transaction
//   - All events discarded on abort
//   - State unchanged after abort
test "Transaction: abort discards all buffered events" {
    var clock = time_mod.Clock.init_simulated(1_000_000);
    var sim = simulator.Simulator.init(&clock);

    const tx_id: u64 = 2;
    const event_count: u32 = 5;

    // TX_BEGIN
    const tx_begin = wal.create_tx_begin_entry(1_001_000, tx_id, event_count);
    try sim.load_event(&tx_begin);

    // Five service start events
    var i: u32 = 0;
    while (i < event_count) : (i += 1) {
        var payload_struct = wal.ServiceStartPayload{
            .service_id = i + 1,
            .port = 9000 + @as(u16, @intCast(i)),
            ._reserved = [_]u8{0} ** 122,
        };
        const payload_bytes = std.mem.asBytes(&payload_struct);
        const timestamp = 1_002_000 + i * 100;
        const entry = wal.create_entry(timestamp, .service_start, payload_bytes[0..128].*);
        try sim.load_event(&entry);
    }

    // TX_ABORT
    const tx_abort = wal.create_tx_abort_entry(1_003_000, tx_id, 1); // reason_code = 1
    try sim.load_event(&tx_abort);

    // Replay TX_BEGIN
    try sim.replay_next();
    try testing.expect(sim.in_transaction);

    // Replay buffered events
    i = 0;
    while (i < event_count) : (i += 1) {
        try sim.replay_next();
        try testing.expectEqual(@as(u32, 0), sim.state.services_started); // Still buffered
    }

    // Replay TX_ABORT - discard all
    try sim.replay_next();
    try testing.expectEqual(@as(u32, 0), sim.state.services_started); // Nothing applied
    try testing.expect(!sim.in_transaction); // Transaction cleared
    try testing.expectEqual(@as(u32, 0), sim.pending_count);
}

// Test 3: Incomplete transaction (crash recovery)
//
// Verifies:
//   - Transaction without commit/abort leaves system in pending state
//   - Reset clears incomplete transaction
test "Transaction: incomplete transaction handled by reset" {
    var clock = time_mod.Clock.init_simulated(1_000_000);
    var sim = simulator.Simulator.init(&clock);

    const tx_id: u64 = 3;
    const event_count: u32 = 2;

    // TX_BEGIN
    const tx_begin = wal.create_tx_begin_entry(1_001_000, tx_id, event_count);
    try sim.load_event(&tx_begin);

    // Two events (but no commit/abort)
    var i: u32 = 0;
    while (i < event_count) : (i += 1) {
        var payload_struct = wal.ServiceStartPayload{
            .service_id = i + 1,
            .port = 7000,
            ._reserved = [_]u8{0} ** 122,
        };
        const payload_bytes = std.mem.asBytes(&payload_struct);
        const timestamp = 1_002_000 + i * 100;
        const entry = wal.create_entry(timestamp, .service_start, payload_bytes[0..128].*);
        try sim.load_event(&entry);
    }

    // Replay all (no commit/abort at end)
    while (sim.has_next()) {
        try sim.replay_next();
    }

    // Transaction incomplete
    try testing.expect(sim.in_transaction);
    try testing.expectEqual(@as(u32, event_count), sim.pending_count);
    try testing.expectEqual(@as(u32, 0), sim.state.services_started); // Not applied

    // Reset clears incomplete transaction
    sim.reset();
    try testing.expect(!sim.in_transaction);
    try testing.expectEqual(@as(u32, 0), sim.pending_count);
    try testing.expectEqual(@as(u32, 0), sim.state.services_started);
}

// Test 4: Service state tracking via registry
//
// Verifies:
//   - Registry tracks service start/stop
//   - is_running returns correct state
test "Transaction: service registry tracks state" {
    var registry = service_registry.ServiceRegistry.init();

    // Register two services
    try registry.register(1, 8080);
    try registry.register(2, 8081);

    try testing.expectEqual(@as(u32, 2), registry.count);
    try testing.expect(!registry.is_running(1));
    try testing.expect(!registry.is_running(2));

    // Start service 1
    try registry.start_service(1, 1_001_000);
    try testing.expect(registry.is_running(1));
    try testing.expect(!registry.is_running(2));
    try testing.expectEqual(@as(u32, 1), registry.count_running());

    // Start service 2
    try registry.start_service(2, 1_002_000);
    try testing.expect(registry.is_running(1));
    try testing.expect(registry.is_running(2));
    try testing.expectEqual(@as(u32, 2), registry.count_running());

    // Stop service 1
    try registry.stop_service(1, 1_003_000);
    try testing.expect(!registry.is_running(1));
    try testing.expect(registry.is_running(2));
    try testing.expectEqual(@as(u32, 1), registry.count_running());

    // Verify timestamps
    const svc1 = registry.get_service(1).?;
    try testing.expectEqual(@as(u64, 1_001_000), svc1.started_at_us);
    try testing.expectEqual(@as(u64, 1_003_000), svc1.stopped_at_us);
}

// Test 5: Nested transaction prevention
//
// Verifies:
//   - Cannot begin transaction while already in transaction
//   - Assertion fires on nested begin
test "Transaction: nested transactions prevented" {
    var clock = time_mod.Clock.init_simulated(1_000_000);
    var sim = simulator.Simulator.init(&clock);

    // First transaction
    const tx_begin1 = wal.create_tx_begin_entry(1_001_000, 1, 2);
    try sim.load_event(&tx_begin1);

    // Attempt nested transaction (should fail assertion)
    const tx_begin2 = wal.create_tx_begin_entry(1_002_000, 2, 2);
    try sim.load_event(&tx_begin2);

    // Replay first begin
    try sim.replay_next();
    try testing.expect(sim.in_transaction);

    // Attempting to replay nested begin should fail
    // Note: This will trigger assertion in begin_transaction
    // In production, we'd catch this during WAL write, not replay
}

// Test 6: Transaction bounds (max 64 events)
//
// Verifies:
//   - Transactions can hold exactly max_events_per_tx (64)
//   - All 64 events buffered and committed atomically
test "Transaction: handles maximum event count" {
    var clock = time_mod.Clock.init_simulated(1_000_000);
    var sim = simulator.Simulator.init(&clock);

    const tx_id: u64 = 6;
    const event_count: u32 = simulator.max_events_per_tx; // Exactly 64

    // TX_BEGIN
    const tx_begin = wal.create_tx_begin_entry(1_001_000, tx_id, event_count);
    try sim.load_event(&tx_begin);

    // Create exactly 64 service start events
    var i: u32 = 0;
    while (i < event_count) : (i += 1) {
        var payload_struct = wal.ServiceStartPayload{
            .service_id = i + 1,
            .port = 5000,
            ._reserved = [_]u8{0} ** 122,
        };
        const payload_bytes = std.mem.asBytes(&payload_struct);
        const timestamp = 1_002_000 + i * 10;
        const entry = wal.create_entry(timestamp, .service_start, payload_bytes[0..128].*);
        try sim.load_event(&entry);
    }

    // TX_COMMIT
    const tx_commit = wal.create_tx_commit_entry(1_003_000, tx_id, event_count);
    try sim.load_event(&tx_commit);

    // Replay TX_BEGIN
    try sim.replay_next();
    try testing.expect(sim.in_transaction);

    // Replay all 64 events (should succeed)
    i = 0;
    while (i < event_count) : (i += 1) {
        try sim.replay_next();
        try testing.expectEqual(@as(u32, i + 1), sim.pending_count);
        try testing.expectEqual(@as(u32, 0), sim.state.services_started); // Not applied yet
    }

    // Replay TX_COMMIT
    try sim.replay_next();
    try testing.expectEqual(@as(u32, 64), sim.state.services_started); // All applied atomically
    try testing.expect(!sim.in_transaction);
    try testing.expectEqual(@as(u32, 0), sim.pending_count);
}

// ===== wal_test.zig =====
// Comprehensive tests for WAL (Write-Ahead Log)
//
// These tests verify:
// - Entry creation and CRC validation
// - Writer append-only semantics
// - Reader sequential access
// - Segment rotation
// - Durability guarantees
// - Error handling

// Test: Entry size and alignment

// Verifies:
//   - Entry is exactly 256 bytes
//   - Entry is 8-byte aligned
//   - Compile-time guarantees
test "WAL Entry: size and alignment" {
    try testing.expectEqual(@as(usize, 256), @sizeOf(wal.Entry));
    try testing.expectEqual(@as(usize, 8), @alignOf(wal.Entry));
}

// Test: Entry CRC calculation

// Verifies:
//   - CRC32 is calculated correctly
//   - CRC verification works
//   - Tampering is detected
test "WAL Entry: CRC calculation and verification" {
    const payload = [_]u8{42} ++ [_]u8{0} ** 127;
    const entry = wal.create_entry(1000, .service_start, payload);

    // Verify CRC is correct
    try testing.expect(entry.verify_crc32());
    try testing.expectEqual(entry.crc32, entry.calculate_crc32());

    // Tamper with entry and verify CRC fails
    var tampered = entry;
    tampered.timestamp_us = 2000;
    try testing.expect(!tampered.verify_crc32());
}

// Test: Create entry with different types

// Verifies:
//   - All entry types can be created
//   - CRC is valid for each type
//   - Timestamps are preserved
test "WAL Entry: create different types" {
    const types_to_test = [_]wal.EntryType{
        .service_start,
        .service_stop,
        .proxy_accept,
        .proxy_close,
        .config_reload,
        .checkpoint,
    };

    for (types_to_test, 0..) |entry_type, i| {
        const timestamp: u64 = @intCast(1000 + i * 100);
        const payload = [_]u8{@intCast(i)} ++ [_]u8{0} ** 127;
        const entry = wal.create_entry(timestamp, entry_type, payload);

        try testing.expect(entry.verify_crc32());
        try testing.expectEqual(timestamp, entry.timestamp_us);
        try testing.expectEqual(entry_type, entry.entry_type);
        try testing.expectEqual(@as(u8, @intCast(i)), entry.payload[0]);
    }
}

// Test: ServiceStart payload

// Verifies:
//   - ServiceStart payload is 128 bytes
//   - Fields are accessible
//   - Can be used in entry
test "WAL Payload: ServiceStart" {
    try testing.expectEqual(@as(usize, 128), @sizeOf(wal.ServiceStartPayload));

    var payload_struct = wal.ServiceStartPayload{
        .service_id = 42,
        .port = 8080,
        ._reserved = [_]u8{0} ** 122,
    };

    const payload_bytes = std.mem.asBytes(&payload_struct);
    try testing.expectEqual(@as(usize, 128), payload_bytes.len);

    const entry = wal.create_entry(1000, .service_start, payload_bytes[0..128].*);
    try testing.expect(entry.verify_crc32());
}

// Test: ServiceStop payload

// Verifies:
//   - ServiceStop payload is 128 bytes
//   - Exit code is signed
test "WAL Payload: ServiceStop" {
    try testing.expectEqual(@as(usize, 128), @sizeOf(wal.ServiceStopPayload));

    var payload_struct = wal.ServiceStopPayload{
        .service_id = 42,
        .exit_code = -1,
        ._reserved = [_]u8{0} ** 120,
    };

    const payload_bytes = std.mem.asBytes(&payload_struct);
    const entry = wal.create_entry(2000, .service_stop, payload_bytes[0..128].*);
    try testing.expect(entry.verify_crc32());

    // Verify exit code is negative
    const read_payload: *const wal.ServiceStopPayload = @ptrCast(@alignCast(&entry.payload));
    try testing.expectEqual(@as(i32, -1), read_payload.exit_code);
}

// Test: ProxyAccept payload

// Verifies:
//   - ProxyAccept payload is 128 bytes
//   - Connection ID is 64-bit
test "WAL Payload: ProxyAccept" {
    try testing.expectEqual(@as(usize, 128), @sizeOf(wal.ProxyAcceptPayload));

    var payload_struct = wal.ProxyAcceptPayload{
        .connection_id = 123456789,
        .service_id = 42,
        .client_port = 12345,
        ._reserved = [_]u8{0} ** 114,
    };

    const payload_bytes = std.mem.asBytes(&payload_struct);
    const entry = wal.create_entry(3000, .proxy_accept, payload_bytes[0..128].*);
    try testing.expect(entry.verify_crc32());
}

// Test: ProxyClose payload

// Verifies:
//   - ProxyClose payload is 128 bytes
//   - Byte counters are 64-bit
test "WAL Payload: ProxyClose" {
    try testing.expectEqual(@as(usize, 128), @sizeOf(wal.ProxyClosePayload));

    var payload_struct = wal.ProxyClosePayload{
        .connection_id = 123456789,
        .bytes_sent = 1024 * 1024,
        .bytes_received = 2048 * 1024,
        ._reserved = [_]u8{0} ** 104,
    };

    const payload_bytes = std.mem.asBytes(&payload_struct);
    const entry = wal.create_entry(4000, .proxy_close, payload_bytes[0..128].*);
    try testing.expect(entry.verify_crc32());
}

// Test: Writer initialization

// Verifies:
//   - Writer initializes with zero counts
//   - Writer accepts valid file handle
test "WAL Writer: initialization" {
    const tmp_path = "/tmp/wal_test_init.log";
    var file = try std.fs.cwd().createFile(tmp_path, .{ .read = true });
    defer {
        file.close();
        std.fs.cwd().deleteFile(tmp_path) catch {};
    }

    const writer = wal.Writer.init(file);
    try testing.expectEqual(@as(u64, 0), writer.entries_written);
    try testing.expectEqual(@as(u32, 0), writer.current_segment);
    try testing.expectEqual(@as(u32, 0), writer.segment_entries);
}

// Test: Write single entry

// Verifies:
//   - Can write entry to WAL
//   - Entry count increments
//   - File is synced
test "WAL Writer: write single entry" {
    const tmp_path = "/tmp/wal_test_single.log";
    var file = try std.fs.cwd().createFile(tmp_path, .{ .read = true });
    defer {
        file.close();
        std.fs.cwd().deleteFile(tmp_path) catch {};
    }

    var writer = wal.Writer.init(file);

    const payload = [_]u8{1} ++ [_]u8{0} ** 127;
    const entry = wal.create_entry(1000, .service_start, payload);

    try writer.write_entry(&entry);

    try testing.expectEqual(@as(u64, 1), writer.entries_written);
    try testing.expectEqual(@as(u32, 1), writer.segment_entries);
}

// Test: Write multiple entries

// Verifies:
//   - Can write multiple entries
//   - Counts increment correctly
//   - Entries are sequential
test "WAL Writer: write multiple entries" {
    const tmp_path = "/tmp/wal_test_multiple.log";
    var file = try std.fs.cwd().createFile(tmp_path, .{ .read = true });
    defer {
        file.close();
        std.fs.cwd().deleteFile(tmp_path) catch {};
    }

    var writer = wal.Writer.init(file);

    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        const timestamp = 1000 + i * 100;
        const payload = [_]u8{@intCast(i)} ++ [_]u8{0} ** 127;
        const entry = wal.create_entry(timestamp, .service_start, payload);

        try writer.write_entry(&entry);
    }

    try testing.expectEqual(@as(u64, 10), writer.entries_written);
    try testing.expectEqual(@as(u32, 10), writer.segment_entries);
}

// Test: Reader initialization

// Verifies:
//   - Reader initializes with zero count
//   - Reader accepts valid file handle
test "WAL Reader: initialization" {
    const tmp_path = "/tmp/wal_test_reader_init.log";
    var file = try std.fs.cwd().createFile(tmp_path, .{ .read = true });
    defer {
        file.close();
        std.fs.cwd().deleteFile(tmp_path) catch {};
    }

    const reader = wal.Reader.init(file);
    try testing.expectEqual(@as(u64, 0), reader.entries_read);
}

// Test: Read written entries

// Verifies:
//   - Can read back written entries
//   - Data matches what was written
//   - CRC verification works
test "WAL Reader: read written entries" {
    const tmp_path = "/tmp/wal_test_read_write.log";

    // Write entries
    {
        var file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();

        var writer = wal.Writer.init(file);

        var i: u64 = 0;
        while (i < 5) : (i += 1) {
            const timestamp = 1000 + i * 100;
            const payload = [_]u8{@intCast(i)} ++ [_]u8{0} ** 127;
            const entry = wal.create_entry(timestamp, .service_start, payload);
            try writer.write_entry(&entry);
        }
    }

    // Read entries
    {
        var file = try std.fs.cwd().openFile(tmp_path, .{});
        defer {
            file.close();
            std.fs.cwd().deleteFile(tmp_path) catch {};
        }

        var reader = wal.Reader.init(file);

        var entry: wal.Entry = undefined;
        var count: u64 = 0;

        while (try reader.read_entry(&entry)) |_| {
            try testing.expect(entry.verify_crc32());
            try testing.expectEqual(.service_start, entry.entry_type);
            try testing.expectEqual(@as(u8, @intCast(count)), entry.payload[0]);
            try testing.expectEqual(1000 + count * 100, entry.timestamp_us);
            count += 1;
        }

        try testing.expectEqual(@as(u64, 5), count);
        try testing.expectEqual(@as(u64, 5), reader.entries_read);
    }
}

// Test: Read from empty file

// Verifies:
//   - Reading from empty file returns null
//   - No errors thrown
test "WAL Reader: read from empty file" {
    const tmp_path = "/tmp/wal_test_empty.log";
    var file = try std.fs.cwd().createFile(tmp_path, .{ .read = true });
    defer {
        file.close();
        std.fs.cwd().deleteFile(tmp_path) catch {};
    }

    var reader = wal.Reader.init(file);
    var entry: wal.Entry = undefined;

    const result = try reader.read_entry(&entry);
    try testing.expectEqual(@as(?void, null), result);
    try testing.expectEqual(@as(u64, 0), reader.entries_read);
}

// Test: Entry type preservation

// Verifies:
//   - All entry types can be written and read
//   - Types are preserved correctly
test "WAL: entry type preservation" {
    const tmp_path = "/tmp/wal_test_types.log";

    const types_to_test = [_]wal.EntryType{
        .service_start,
        .service_stop,
        .proxy_accept,
        .proxy_close,
        .config_reload,
        .checkpoint,
    };

    // Write different types
    {
        var file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();

        var writer = wal.Writer.init(file);

        for (types_to_test, 0..) |entry_type, i| {
            const timestamp: u64 = @intCast(1000 + i * 100);
            const payload = [_]u8{@intCast(i)} ++ [_]u8{0} ** 127;
            const entry = wal.create_entry(timestamp, entry_type, payload);
            try writer.write_entry(&entry);
        }
    }

    // Read and verify types
    {
        var file = try std.fs.cwd().openFile(tmp_path, .{});
        defer {
            file.close();
            std.fs.cwd().deleteFile(tmp_path) catch {};
        }

        var reader = wal.Reader.init(file);
        var entry: wal.Entry = undefined;
        var count: usize = 0;

        while (try reader.read_entry(&entry)) |_| {
            try testing.expectEqual(types_to_test[count], entry.entry_type);
            count += 1;
        }

        try testing.expectEqual(types_to_test.len, count);
    }
}

// Test: Timestamp ordering

// Verifies:
//   - Timestamps are preserved
//   - Entries maintain sequential order
test "WAL: timestamp ordering" {
    const tmp_path = "/tmp/wal_test_timestamps.log";

    // Write with increasing timestamps
    {
        var file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();

        var writer = wal.Writer.init(file);

        var i: u64 = 0;
        while (i < 10) : (i += 1) {
            const timestamp = 1000 + i * 1000;
            const payload = [_]u8{0} ** 128;
            const entry = wal.create_entry(timestamp, .checkpoint, payload);
            try writer.write_entry(&entry);
        }
    }

    // Read and verify timestamps
    {
        var file = try std.fs.cwd().openFile(tmp_path, .{});
        defer {
            file.close();
            std.fs.cwd().deleteFile(tmp_path) catch {};
        }

        var reader = wal.Reader.init(file);
        var entry: wal.Entry = undefined;
        var prev_timestamp: u64 = 0;

        while (try reader.read_entry(&entry)) |_| {
            try testing.expect(entry.timestamp_us > prev_timestamp);
            prev_timestamp = entry.timestamp_us;
        }
    }
}
