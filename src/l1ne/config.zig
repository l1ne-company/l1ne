//! Configuration parser for L1NE
//!
//! This module reads Nix configuration files and extracts runtime limits
//! that determine static memory allocation. The config defines:
//!
//! - Number of service instances
//! - Connection pool sizes
//! - Buffer sizes
//! - Resource limits
//!
//! Expected Nix config format:
//!
//! {
//!   services = {
//!     max_instances = 4;
//!     instances = [
//!       {
//!         name = "service-1";
//!         exec = "./path/to/binary";
//!         port = 8080;
//!       }
//!     ];
//!   };
//!
//!   runtime = {
//!     proxy_connections_max = 256;
//!     proxy_buffer_size_kb = 4;
//!     cgroup_monitors_max = 4;
//!     systemd_buffer_size_kb = 4;
//!   };
//! }

const std = @import("std");
const nix = @import("nix");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const constants = @import("constants.zig");
const RuntimeLimits = constants.RuntimeLimits;
const scenario_mod = @import("scenario.zig");
const fault_injector_mod = @import("fault_injector.zig");

/// Service configuration from Nix file
pub const ServiceConfig = struct {
    name: []const u8,
    exec_path: []const u8,
    port: u16,
    memory_mb: u32,
    cpu_percent: u8,
};

/// Complete L1NE configuration
pub const Config = struct {
    limits: RuntimeLimits,
    services: []ServiceConfig,
    allocator: Allocator,

    /// Load configuration from Nix file
    ///
    /// Invariants:
    ///   - Pre: allocator is valid
    ///   - Pre: path is non-empty and ends with .nix
    ///   - Pre: path length < max_path_bytes
    ///   - Post: returned Config is valid with services allocated
    pub fn from_nix_file(allocator: Allocator, path: []const u8) !Config {
        assert(@intFromPtr(allocator.ptr) != 0); // Allocator must be valid
        assert(path.len > 0); // Path must be non-empty
        assert(path.len < std.fs.max_path_bytes); // Path must be reasonable
        assert(std.mem.endsWith(u8, path, ".nix")); // Must be .nix file

        // Resolve to absolute path so relative exec paths can be normalized later
        const absolute_path = std.fs.cwd().realpathAlloc(allocator, path) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.err("Config file not found: {s}", .{path});
                return error.ConfigNotFound;
            },
            error.AccessDenied => {
                std.log.err("Config file not accessible: {s}", .{path});
                return error.ConfigNotAccessible;
            },
            else => return err,
        };
        defer allocator.free(absolute_path);

        // Read entire file into memory
        const source = std.fs.cwd().readFileAlloc(
            allocator,
            path,
            10 * types.MIB, // Max 10 MiB config file
        ) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.err("Config file not found: {s}", .{path});
                return error.ConfigNotFound;
            },
            error.AccessDenied => {
                std.log.err("Config file not accessible: {s}", .{path});
                return error.ConfigNotAccessible;
            },
            error.FileTooBig => {
                std.log.err("Config file too large (>10 MiB): {s}", .{path});
                return error.ConfigTooLarge;
            },
            else => {
                std.log.err("Failed to read config file {s}: {any}", .{ path, err });
                return err;
            },
        };
        defer allocator.free(source);

        assert(source.len > 0); // File must not be empty
        assert(source.len <= 10 * types.MIB); // Size must be within limit

        // Parse Nix source to CST
        var cst = nix.parse(allocator, source) catch |err| {
            std.log.err("Failed to parse Nix config {s}: {any}", .{ path, err });
            std.log.err("This may indicate invalid Nix syntax in the config file", .{});
            return err;
        };
        defer cst.deinit();

        assert(@intFromPtr(cst.root) != 0); // CST must have valid root

        // Extract configuration from CST
        var config = try extract_config(allocator, cst, source);
        errdefer config.deinit();

        const base_dir = std.fs.path.dirname(absolute_path) orelse absolute_path;
        try config.absolutize_exec_paths(base_dir);

        return config;
    }

    /// Load configuration from Nix source string
    ///
    /// Invariants:
    ///   - Pre: allocator is valid
    ///   - Pre: source is non-empty
    ///   - Pre: source length < 10 MiB
    ///   - Post: returned Config is valid with services allocated
    pub fn from_nix_source(allocator: Allocator, source: []const u8) !Config {
        assert(@intFromPtr(allocator.ptr) != 0); // Allocator must be valid
        assert(source.len > 0); // Source must not be empty
        assert(source.len <= 10 * types.MIB); // Source must be reasonable size

        // Parse Nix source to CST
        var cst = try nix.parse(allocator, source);
        defer cst.deinit();

        assert(@intFromPtr(cst.root) != 0); // CST must have valid root

        // Extract configuration from CST
        return try extract_config(allocator, cst, source);
    }

    /// Convert relative service exec paths to absolute paths
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: base_dir is absolute and non-empty
    ///   - Post: all service.exec_path values are absolute
    pub fn absolutize_exec_paths(self: *Config, base_dir: []const u8) !void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(base_dir.len > 0); // Base directory must be non-empty
        assert(std.fs.path.isAbsolute(base_dir)); // Base directory must be absolute

        for (self.services) |*service| {
            assert(service.exec_path.len > 0); // Exec path must be non-empty

            if (std.fs.path.isAbsolute(service.exec_path)) continue;

            const old_path = service.exec_path;
            const absolute_exec = try std.fs.path.resolve(
                self.allocator,
                &[_][]const u8{ base_dir, old_path },
            );
            errdefer self.allocator.free(absolute_exec);

            self.allocator.free(old_path);
            service.exec_path = absolute_exec;
        }
    }

    /// Free all allocated memory for this configuration
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: allocator matches the one used for allocation
    ///   - Post: all service strings and service array freed
    pub fn deinit(self: *Config) void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(@intFromPtr(self.allocator.ptr) != 0); // Allocator must be valid

        for (self.services) |service| {
            assert(service.name.len > 0); // Name must be non-empty
            assert(service.exec_path.len > 0); // Path must be non-empty
            self.allocator.free(service.name);
            self.allocator.free(service.exec_path);
        }
        self.allocator.free(self.services);
    }
};

/// Extract configuration from parsed CST
///
/// Invariants:
///   - Pre: allocator is valid
///   - Pre: cst.root is valid pointer
///   - Pre: source is non-empty
///   - Pre: services_count <= 16 (bounded array limit)
///   - Post: returned Config has validated limits
///   - Post: services array is allocated on heap
fn extract_config(allocator: Allocator, cst: nix.CST, source: []const u8) !Config {
    assert(@intFromPtr(allocator.ptr) != 0); // Allocator must be valid
    assert(@intFromPtr(cst.root) != 0); // CST must have valid root
    assert(source.len > 0); // Source must not be empty

    var limits = constants.default_limits; // Start with defaults
    // Use a bounded array for services instead of ArrayList
    var services_temp: [16]ServiceConfig = undefined;
    var services_count: usize = 0;

    // Walk CST to find configuration nodes
    // The root should contain an ATTR_SET, and that set contains ATTRPATH_VALUE nodes

    // Find the attr set node (first child of root)
    var attr_set_node: ?*nix.Node = null;
    for (cst.root.children.items) |child| {
        switch (child.kind) {
            .node => |nk| {
                if (nk == .NODE_ATTR_SET) {
                    attr_set_node = child;
                    break;
                }
            },
            else => {},
        }
    }

    if (attr_set_node) |set_node| {
        // Find runtime and services attributes within the attr set
        for (set_node.children.items) |child| {
            switch (child.kind) {
                .node => |node_kind| {
                    if (node_kind != .NODE_ATTRPATH_VALUE) continue;
                },
                else => continue,
            }

            // Get the attribute name
            const attr_name = try get_attrpath_name(child, source);
            assert(attr_name.len > 0); // Attribute name must be non-empty

            if (std.mem.eql(u8, attr_name, "runtime")) {
                // Extract runtime limits
                limits = try extract_runtime_limits(child, source);
            } else if (std.mem.eql(u8, attr_name, "services")) {
                // Extract services configuration
                try extract_services(allocator, &services_temp, &services_count, child, source);
            }
        }
    }

    assert(services_count <= 16); // Must not exceed bounded array size

    // Validate limits
    try limits.validate();

    // Ensure we have at least one service
    if (services_count == 0) {
        std.log.warn("No services configured, using defaults", .{});
    }

    // Copy services to heap
    const services_slice = try allocator.alloc(ServiceConfig, services_count);
    @memcpy(services_slice, services_temp[0..services_count]);

    assert(services_slice.len == services_count); // Slice length must match count

    return Config{
        .limits = limits,
        .services = services_slice,
        .allocator = allocator,
    };
}

/// Get attribute path name from a NODE_ATTRPATH_VALUE node
///
/// Invariants:
///   - Pre: node is valid pointer
///   - Pre: source is non-empty
///   - Pre: node has NODE_ATTRPATH_VALUE kind
///   - Post: returned slice is within source bounds
///   - Post: returned slice is non-empty
fn get_attrpath_name(node: *nix.Node, source: []const u8) ![]const u8 {
    assert(@intFromPtr(node) != 0); // Node must be valid
    assert(source.len > 0); // Source must not be empty

    // Find the attrpath child (first child typically)
    for (node.children.items) |child| {
        switch (child.kind) {
            .node => |node_kind| {
                if (node_kind == .NODE_ATTRPATH) {
                    // Get the identifier from the attrpath
                    // Structure: NODE_ATTRPATH -> NODE_IDENT -> TOKEN_IDENT
                    for (child.children.items) |ident_node| {
                        switch (ident_node.kind) {
                            .node => |ink| {
                                if (ink == .NODE_IDENT) {
                                    // Now find TOKEN_IDENT within NODE_IDENT
                                    for (ident_node.children.items) |token_node| {
                                        switch (token_node.kind) {
                                            .token => |tk| {
                                                if (tk == .TOKEN_IDENT) {
                                                    assert(token_node.start < source.len); // Start must be in bounds
                                                    assert(token_node.end <= source.len); // End must be in bounds
                                                    assert(token_node.start < token_node.end); // Range must be valid
                                                    const result = source[token_node.start..token_node.end];
                                                    assert(result.len > 0); // Result must be non-empty
                                                    return result;
                                                }
                                            },
                                            else => {},
                                        }
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                }
            },
            else => {},
        }
    }

    return error.InvalidAttrPath;
}

/// Extract runtime limits from Nix attrset
///
/// Invariants:
///   - Pre: node is valid pointer
///   - Pre: source is non-empty
///   - Pre: node has NODE_ATTRPATH_VALUE kind
///   - Post: returned limits are based on default_limits
///   - Post: numeric values fit in target types after @intCast
fn extract_runtime_limits(node: *nix.Node, source: []const u8) !RuntimeLimits {
    assert(@intFromPtr(node) != 0); // Node must be valid
    assert(source.len > 0); // Source must not be empty

    var limits = constants.default_limits; // Start with defaults

    // Find the attribute set value (should be exactly one)
    // Structure: NODE_ATTRPATH_VALUE -> NODE_ATTRPATH, NODE_ATTR_SET
    var found_attr_set = false;
    for (node.children.items) |child| {
        switch (child.kind) {
            .node => |nk| if (nk != .NODE_ATTR_SET) continue,
            else => continue,
        }

        // Should only process the first (and only) attr set
        if (found_attr_set) {
            std.log.warn("WARNING: Found multiple ATTR_SET nodes in runtime limits", .{});
            continue;
        }
        found_attr_set = true;

        // Walk attributes in the set
        for (child.children.items) |attr_node| {
            // Only process NODE_ATTRPATH_VALUE nodes
            switch (attr_node.kind) {
                .node => |nk| {
                    if (nk != .NODE_ATTRPATH_VALUE) continue;
                },
                else => continue,
            }

            // Extract attribute name and value
            const attr_name = get_attrpath_name(attr_node, source) catch continue;
            const value = extract_integer_value(attr_node, source) catch continue;

            assert(attr_name.len > 0); // Attribute name must be non-empty
            assert(value >= 0); // Values must be non-negative

            // Map attribute names to RuntimeLimits fields
            if (std.mem.eql(u8, attr_name, "proxy_connections_max")) {
                limits.proxy_connections_max = @intCast(value);
            } else if (std.mem.eql(u8, attr_name, "proxy_buffer_size_kb")) {
                limits.proxy_buffer_size = @intCast(value * types.KIB);
            } else if (std.mem.eql(u8, attr_name, "cgroup_monitors_max")) {
                limits.cgroup_monitors_count = @intCast(value);
            } else if (std.mem.eql(u8, attr_name, "systemd_buffer_size_kb")) {
                limits.systemd_buffer_size = @intCast(value * types.KIB);
            }
        }
    }

    return limits;
}

/// Extract services configuration from Nix attrset
///
/// Invariants:
///   - Pre: allocator is valid
///   - Pre: services slice is valid with len <= 16
///   - Pre: count points to valid usize
///   - Pre: node is valid pointer
///   - Pre: source is non-empty
///   - Post: count <= services.len (no overflow)
fn extract_services(
    allocator: Allocator,
    services: []ServiceConfig,
    count: *usize,
    node: *nix.Node,
    source: []const u8,
) !void {
    assert(@intFromPtr(allocator.ptr) != 0); // Allocator must be valid
    assert(services.len <= 16); // Bounded array limit
    assert(@intFromPtr(count) != 0); // Count pointer must be valid
    assert(@intFromPtr(node) != 0); // Node must be valid
    assert(source.len > 0); // Source must not be empty

    // Find the attribute set value
    for (node.children.items) |child| {
        switch (child.kind) {
            .node => |nk| {
                if (nk == .NODE_ATTR_SET) {
                    // Walk attributes in the services set
                    for (child.children.items) |attr_node| {
                        switch (attr_node.kind) {
                            .node => |ank| {
                                if (ank != .NODE_ATTRPATH_VALUE) continue;

                                const attr_name = try get_attrpath_name(attr_node, source);
                                assert(attr_name.len > 0); // Attribute name must be non-empty

                                if (std.mem.eql(u8, attr_name, "max_instances")) {
                                    // Extract max_instances count
                                    // (Currently unused, but available for validation)
                                    _ = try extract_integer_value(attr_node, source);
                                } else if (std.mem.eql(u8, attr_name, "instances")) {
                                    // Extract list of service instances
                                    try extract_service_instances(allocator, services, count, attr_node, source);
                                }
                            },
                            else => {},
                        }
                    }
                }
            },
            else => {},
        }
    }

    assert(count.* <= services.len); // Must not overflow services array
}

/// Extract service instances from a list
///
/// Invariants:
///   - Pre: allocator is valid
///   - Pre: services slice is valid with len <= 16
///   - Pre: count points to valid usize
///   - Pre: node is valid pointer
///   - Pre: source is non-empty
///   - Post: count <= services.len (no overflow)
fn extract_service_instances(
    allocator: Allocator,
    services: []ServiceConfig,
    count: *usize,
    node: *nix.Node,
    source: []const u8,
) !void {
    assert(@intFromPtr(allocator.ptr) != 0); // Allocator must be valid
    assert(services.len <= 16); // Bounded array limit
    assert(@intFromPtr(count) != 0); // Count pointer must be valid
    assert(@intFromPtr(node) != 0); // Node must be valid
    assert(source.len > 0); // Source must not be empty

    const initial_count = count.*;

    // Find the list node
    for (node.children.items) |child| {
        switch (child.kind) {
            .node => |nk| {
                if (nk == .NODE_LIST) {
                    // Walk each element in the list
                    for (child.children.items) |elem_node| {
                        switch (elem_node.kind) {
                            .node => |enk| {
                                if (enk == .NODE_ATTR_SET) {
                                    if (count.* >= services.len) return error.TooManyServices;
                                    const service = try extract_service_config(allocator, elem_node, source);
                                    assert(service.name.len > 0); // Service name must be non-empty
                                    assert(service.exec_path.len > 0); // Service path must be non-empty
                                    services[count.*] = service;
                                    count.* += 1;
                                }
                            },
                            else => {},
                        }
                    }
                }
            },
            else => {},
        }
    }

    assert(count.* >= initial_count); // Count must not decrease
    assert(count.* <= services.len); // Must not overflow services array
}

/// Extract a single service config from an attrset
///
/// Invariants:
///   - Pre: allocator is valid
///   - Pre: node is valid pointer
///   - Pre: source is non-empty
///   - Pre: node has NODE_ATTR_SET kind
///   - Post: returned ServiceConfig has non-empty name and exec_path
///   - Post: port is in range 1..65535
fn extract_service_config(allocator: Allocator, node: *nix.Node, source: []const u8) !ServiceConfig {
    assert(@intFromPtr(allocator.ptr) != 0); // Allocator must be valid
    assert(@intFromPtr(node) != 0); // Node must be valid
    assert(source.len > 0); // Source must not be empty

    var name: ?[]const u8 = null;
    var exec_path: ?[]const u8 = null;
    var port: u16 = 8080; // Default port
    var memory_mb: u32 = 50; // Default memory
    var cpu_percent: u8 = 10; // Default CPU

    // Walk attributes in the service config
    for (node.children.items) |attr_node| {
        switch (attr_node.kind) {
            .node => |nk| {
                if (nk != .NODE_ATTRPATH_VALUE) continue;

                const attr_name = try get_attrpath_name(attr_node, source);
                assert(attr_name.len > 0); // Attribute name must be non-empty

                if (std.mem.eql(u8, attr_name, "name")) {
                    const str = try extract_string_value(attr_node, source);
                    name = try allocator.dupe(u8, str);
                } else if (std.mem.eql(u8, attr_name, "exec")) {
                    const str = try extract_string_value(attr_node, source);
                    exec_path = try allocator.dupe(u8, str);
                } else if (std.mem.eql(u8, attr_name, "port")) {
                    port = @intCast(try extract_integer_value(attr_node, source));
                } else if (std.mem.eql(u8, attr_name, "memory_mb")) {
                    memory_mb = @intCast(try extract_integer_value(attr_node, source));
                } else if (std.mem.eql(u8, attr_name, "cpu_percent")) {
                    cpu_percent = @intCast(try extract_integer_value(attr_node, source));
                }
            },
            else => {},
        }
    }

    if (name == null or exec_path == null) {
        std.log.err("Service config missing required fields (name or exec)", .{});
        return error.IncompleteServiceConfig;
    }

    assert(name.?.len > 0); // Name must be non-empty
    assert(exec_path.?.len > 0); // Path must be non-empty
    assert(port > 0); // Port must be valid
    assert(port < 65536); // Port must be in range

    return ServiceConfig{
        .name = name.?,
        .exec_path = exec_path.?,
        .port = port,
        .memory_mb = memory_mb,
        .cpu_percent = cpu_percent,
    };
}

/// Extract integer value from a Nix literal node
///
/// Invariants:
///   - Pre: node is valid pointer
///   - Pre: source is non-empty
///   - Post: returned value >= 0
///   - Post: returned value can be parsed as base-10 u64
fn extract_integer_value(node: *nix.Node, source: []const u8) !u64 {
    assert(@intFromPtr(node) != 0); // Node must be valid
    assert(source.len > 0); // Source must not be empty

    // Find the literal node
    for (node.children.items) |child| {
        switch (child.kind) {
            .node => |nk| {
                if (nk == .NODE_LITERAL) {
                    // Find the integer token within the literal
                    for (child.children.items) |token_node| {
                        switch (token_node.kind) {
                            .token => |tk| {
                                if (tk == .TOKEN_INTEGER) {
                                    assert(token_node.start < source.len); // Start must be in bounds
                                    assert(token_node.end <= source.len); // End must be in bounds
                                    assert(token_node.start < token_node.end); // Range must be valid
                                    const int_str = source[token_node.start..token_node.end];
                                    assert(int_str.len > 0); // Integer string must be non-empty
                                    const result = try std.fmt.parseInt(u64, int_str, 10);
                                    assert(result >= 0); // Result must be non-negative
                                    return result;
                                }
                            },
                            else => {},
                        }
                    }
                }
            },
            else => {},
        }
    }
    return error.IntegerNotFound;
}

/// Extract string value from a Nix string node
///
/// Invariants:
///   - Pre: node is valid pointer
///   - Pre: source is non-empty
///   - Post: returned slice is within source bounds
///   - Post: returned slice is non-empty
fn extract_string_value(node: *nix.Node, source: []const u8) ![]const u8 {
    assert(@intFromPtr(node) != 0); // Node must be valid
    assert(source.len > 0); // Source must not be empty

    // Find the string node
    for (node.children.items) |child| {
        switch (child.kind) {
            .node => |nk| {
                if (nk == .NODE_STRING) {
                    // Find the string content token
                    for (child.children.items) |token_node| {
                        switch (token_node.kind) {
                            .token => |tk| {
                                if (tk == .TOKEN_STRING_CONTENT) {
                                    assert(token_node.start < source.len); // Start must be in bounds
                                    assert(token_node.end <= source.len); // End must be in bounds
                                    assert(token_node.start < token_node.end); // Range must be valid
                                    const result = source[token_node.start..token_node.end];
                                    assert(result.len > 0); // Result must be non-empty
                                    return result;
                                }
                            },
                            else => {},
                        }
                    }
                }
            },
            else => {},
        }
    }
    return error.StringNotFound;
}

test "Config: parse simple Nix config" {
    const source =
        \\{
        \\  runtime = {
        \\    proxy_connections_max = 128;
        \\    proxy_buffer_size_kb = 8;
        \\  };
        \\}
    ;

    var config = try Config.from_nix_source(std.testing.allocator, source);
    defer config.deinit();

    try std.testing.expectEqual(@as(u32, 128), config.limits.proxy_connections_max);
    try std.testing.expectEqual(@as(u32, 8 * types.KIB), config.limits.proxy_buffer_size);
}
