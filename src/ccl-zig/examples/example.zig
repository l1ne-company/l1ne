const std = @import("std");
const ccl = @import("ccl");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Example CCL configuration
    const input =
        \\name = MyApp
        \\version = 1.0.0
        \\debug = true
        \\server =
        \\  host = localhost
        \\  port = 8080
        \\/= List of features
        \\= auth
        \\= logging
        \\= metrics
    ;

    std.debug.print("=== CCL Parser Example ===\n\n", .{});
    std.debug.print("Input:\n{s}\n\n", .{input});

    // Example 1: Parse into AST and access values directly
    std.debug.print("--- Example 1: AST API ---\n", .{});
    {
        var config = try ccl.parse(allocator, input);
        defer config.deinit(allocator);

        // Access individual values
        if (config.get("name")) |name_value| {
            std.debug.print("name = {s}\n", .{name_value.string});
        }

        if (config.get("debug")) |debug_value| {
            std.debug.print("debug = {s}\n", .{debug_value.string});
        }

        // Access nested values
        if (config.get("server")) |server_value| {
            switch (server_value.*) {
                .nested => |*nested_config| {
                    if (nested_config.get("host")) |host| {
                        std.debug.print("server.host = {s}\n", .{host.string});
                    }
                    if (nested_config.get("port")) |port| {
                        std.debug.print("server.port = {s}\n", .{port.string});
                    }
                },
                else => {},
            }
        }

        // Get all list items (empty key)
        var features = try config.getAll("", allocator);
        defer features.deinit(allocator);

        std.debug.print("features ({d} items):\n", .{features.items.len});
        for (features.items) |feature| {
            std.debug.print("  - {s}\n", .{feature.string});
        }
    }

    std.debug.print("\n--- Example 2: Deserialize into Struct ---\n", .{});

    // Example 2: Deserialize directly into a typed struct
    {
        const AppConfig = struct {
            name: []const u8,
            version: []const u8,
            debug: bool,
        };

        const app_config = try ccl.deserialize.parseInto(AppConfig, allocator, input);

        std.debug.print("AppConfig {{\n", .{});
        std.debug.print("  name: \"{s}\"\n", .{app_config.name});
        std.debug.print("  version: \"{s}\"\n", .{app_config.version});
        std.debug.print("  debug: {}\n", .{app_config.debug});
        std.debug.print("}}\n", .{});
    }

    // Example 3: Deserialize with nested structs
    std.debug.print("\n--- Example 3: Nested Structs ---\n", .{});
    {
        const ServerConfig = struct {
            host: []const u8,
            port: u32,
        };

        const FullConfig = struct {
            name: []const u8,
            version: []const u8,
            debug: bool,
            server: ServerConfig,
        };

        const full_config = try ccl.deserialize.parseInto(FullConfig, allocator, input);

        std.debug.print("FullConfig {{\n", .{});
        std.debug.print("  name: \"{s}\"\n", .{full_config.name});
        std.debug.print("  version: \"{s}\"\n", .{full_config.version});
        std.debug.print("  debug: {}\n", .{full_config.debug});
        std.debug.print("  server: {{\n", .{});
        std.debug.print("    host: \"{s}\"\n", .{full_config.server.host});
        std.debug.print("    port: {}\n", .{full_config.server.port});
        std.debug.print("  }}\n", .{});
        std.debug.print("}}\n", .{});
    }

    // Example 4: Optional fields and defaults
    std.debug.print("\n--- Example 4: Optional Fields ---\n", .{});
    {
        const ConfigWithOptionals = struct {
            name: []const u8,
            version: []const u8,
            timeout: ?u32 = null,
            retries: u32 = 3,
        };

        const config = try ccl.deserialize.parseInto(ConfigWithOptionals, allocator, input);

        std.debug.print("ConfigWithOptionals {{\n", .{});
        std.debug.print("  name: \"{s}\"\n", .{config.name});
        std.debug.print("  version: \"{s}\"\n", .{config.version});
        std.debug.print("  timeout: {?}\n", .{config.timeout});
        std.debug.print("  retries: {} (default)\n", .{config.retries});
        std.debug.print("}}\n", .{});
    }

    std.debug.print("\n=== All examples completed successfully! ===\n", .{});
}

test "usage example" {
    const allocator = std.testing.allocator;

    const input =
        \\name = MyApp
        \\version = 1.0.0
        \\debug = true
        \\server =
        \\  host = localhost
        \\  port = 8080
        \\/= List of features
        \\= auth
        \\= logging
        \\= metrics
    ;

    // Test AST API
    var config = try ccl.parse(allocator, input);
    defer config.deinit(allocator);

    const name_value = config.get("name");
    try std.testing.expect(name_value != null);
    try std.testing.expectEqualStrings("MyApp", name_value.?.string);

    // Test deserialization
    const AppConfig = struct {
        name: []const u8,
        version: []const u8,
        debug: bool,
    };

    const app_config = try ccl.deserialize.parseInto(AppConfig, allocator, input);
    try std.testing.expectEqualStrings("MyApp", app_config.name);
    try std.testing.expectEqualStrings("1.0.0", app_config.version);
    try std.testing.expectEqual(true, app_config.debug);

    // Test nested deserialization
    const ServerConfig = struct {
        host: []const u8,
        port: u32,
    };

    const FullConfig = struct {
        name: []const u8,
        version: []const u8,
        debug: bool,
        server: ServerConfig,
    };

    const full_config = try ccl.deserialize.parseInto(FullConfig, allocator, input);
    try std.testing.expectEqualStrings("MyApp", full_config.name);
    try std.testing.expectEqualStrings("localhost", full_config.server.host);
    try std.testing.expectEqual(@as(u32, 8080), full_config.server.port);
}
