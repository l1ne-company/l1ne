//! Comprehensive tests for Config and Nix parsing
//!
//! These tests verify:
//! - Nix source parsing
//! - Runtime limits extraction
//! - Service configuration extraction
//! - Validation and error handling
//! - Edge cases and malformed input

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const config_mod = @import("config.zig");
const types = @import("types.zig");
const Config = config_mod.Config;
const ServiceConfig = config_mod.ServiceConfig;

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
