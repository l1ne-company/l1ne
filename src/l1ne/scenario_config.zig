//! Scenario Configuration Parser
//!
//! Parses scenario definitions from Nix files for simulation testing.
//!
//! Expected format:
//! {
//!   scenario = {
//!     name = "chaos-test";
//!     type = "chaos_test";
//!     duration_us = 60000000;
//!     seed = 12345;
//!     services = [
//!       { service_id = 1; port = 8080; }
//!       { service_id = 2; port = 8081; }
//!     ];
//!     faults = {
//!       crash_probability = 0.05;
//!       delay_probability = 0.1;
//!     };
//!   };
//! }

const std = @import("std");
const nix = @import("nix");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const scenario_mod = @import("scenario.zig");
const fault_injector_mod = @import("fault_injector.zig");

/// Scenario configuration from Nix file
pub const ScenarioConfig = struct {
    name: []const u8,
    scenario_type: scenario_mod.ScenarioType,
    services: []scenario_mod.ServiceConfig,
    duration_us: u64,
    seed: u64,
    fault_config: fault_injector_mod.FaultConfig,
    allocator: Allocator,

    /// Load scenario config from Nix file
    ///
    /// Invariants:
    ///   - Pre: allocator is valid
    ///   - Pre: path is non-empty and ends with .nix
    ///   - Post: returned ScenarioConfig is valid
    pub fn from_nix_file(allocator: Allocator, path: []const u8) !ScenarioConfig {
        assert(@intFromPtr(allocator.ptr) != 0); // Allocator must be valid
        assert(path.len > 0); // Path must be non-empty
        assert(std.mem.endsWith(u8, path, ".nix")); // Must be .nix file

        // Read file
        const source = std.fs.cwd().readFileAlloc(
            allocator,
            path,
            10 * types.MIB,
        ) catch |err| {
            std.log.err("Failed to read scenario config {s}: {any}", .{ path, err });
            return err;
        };
        defer allocator.free(source);

        assert(source.len > 0); // File must not be empty

        // Parse Nix source
        var cst = nix.parse(allocator, source) catch |err| {
            std.log.err("Failed to parse scenario config {s}: {any}", .{ path, err });
            return err;
        };
        defer cst.deinit();

        assert(@intFromPtr(cst.root) != 0); // CST must have valid root

        // Extract scenario config
        return try extract_scenario(allocator, cst, source);
    }

    /// Free all allocated memory
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: all memory freed
    pub fn deinit(self: *ScenarioConfig) void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(@intFromPtr(self.allocator.ptr) != 0); // Allocator must be valid

        self.allocator.free(self.name);
        self.allocator.free(self.services);
    }
};

/// Extract scenario configuration from CST
///
/// Invariants:
///   - Pre: allocator is valid
///   - Pre: cst has valid root
///   - Pre: source is non-empty
///   - Post: returned ScenarioConfig is complete
fn extract_scenario(
    allocator: Allocator,
    cst: nix.CST,
    source: []const u8,
) !ScenarioConfig {
    assert(@intFromPtr(allocator.ptr) != 0); // Allocator must be valid
    assert(@intFromPtr(cst.root) != 0); // CST root must be valid
    assert(source.len > 0); // Source must not be empty

    // The CST structure is:
    // NODE_ROOT -> NODE_ATTR_SET -> NODE_ATTRPATH_VALUE("scenario") -> NODE_ATTR_SET(fields)

    // Find the top-level NODE_ATTR_SET
    for (cst.root.children.items) |top_level_node| {
        switch (top_level_node.kind) {
            .node => |tlnk| {
                if (tlnk == .NODE_ATTR_SET) {
                    // Look for "scenario" attribute
                    for (top_level_node.children.items) |attr_node| {
                        switch (attr_node.kind) {
                            .node => |ank| {
                                if (ank == .NODE_ATTRPATH_VALUE) {
                                    const attr_name = get_attrpath_name(attr_node, source) catch continue;
                                    if (std.mem.eql(u8, attr_name, "scenario")) {
                                        // Found "scenario", now find its NODE_ATTR_SET value
                                        for (attr_node.children.items) |value_node| {
                                            switch (value_node.kind) {
                                                .node => |vnk| {
                                                    if (vnk == .NODE_ATTR_SET) {
                                                        // This is the scenario object - extract all fields
                                                        return try build_scenario_config(
                                                            allocator,
                                                            value_node,
                                                            source,
                                                        );
                                                    }
                                                },
                                                else => {},
                                            }
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

    std.log.err("Scenario attribute not found in Nix file", .{});
    return error.ScenarioNotFound;
}

/// Build ScenarioConfig from the scenario attribute set node
fn build_scenario_config(
    allocator: Allocator,
    scenario_node: *nix.Node,
    source: []const u8,
) !ScenarioConfig {
    var name: ?[]const u8 = null;
    var scenario_type: ?scenario_mod.ScenarioType = null;
    var duration_us: u64 = 0;
    var seed: u64 = 12345; // Default seed
    var services_list: ?[]scenario_mod.ServiceConfig = null;
    var fault_config = fault_injector_mod.FaultConfig{};

    // Extract all fields from scenario object
    name = try extract_field_string(allocator, scenario_node, source, "name");
    scenario_type = try extract_scenario_type(scenario_node, source);
    duration_us = try extract_field_u64(scenario_node, source, "duration_us");
    seed = extract_field_u64(scenario_node, source, "seed") catch seed;
    services_list = try extract_scenario_services(allocator, scenario_node, source);
    fault_config = extract_fault_config(scenario_node, source) catch fault_injector_mod.FaultConfig{};

    if (name == null or scenario_type == null or services_list == null) {
        std.log.err("Scenario config missing required fields", .{});
        return error.IncompleteScenarioConfig;
    }

    assert(name.?.len > 0); // Name must be non-empty
    assert(duration_us > 0); // Duration must be positive
    assert(services_list.?.len > 0); // Must have at least one service

    return ScenarioConfig{
        .name = name.?,
        .scenario_type = scenario_type.?,
        .services = services_list.?,
        .duration_us = duration_us,
        .seed = seed,
        .fault_config = fault_config,
        .allocator = allocator,
    };
}

/// Extract scenario type from string
fn extract_scenario_type(node: *nix.Node, source: []const u8) !scenario_mod.ScenarioType {
    const type_str = try extract_field_string(std.heap.page_allocator, node, source, "type");
    defer std.heap.page_allocator.free(type_str);

    if (std.mem.eql(u8, type_str, "load_test")) return .load_test;
    if (std.mem.eql(u8, type_str, "chaos_test")) return .chaos_test;
    if (std.mem.eql(u8, type_str, "transaction_stress")) return .transaction_stress;
    if (std.mem.eql(u8, type_str, "lifecycle_test")) return .lifecycle_test;
    if (std.mem.eql(u8, type_str, "custom")) return .custom;

    std.log.err("Unknown scenario type: {s}", .{type_str});
    return error.UnknownScenarioType;
}

/// Extract services list from scenario config
fn extract_scenario_services(
    allocator: Allocator,
    node: *nix.Node,
    source: []const u8,
) ![]scenario_mod.ServiceConfig {
    var services_array: [64]scenario_mod.ServiceConfig = undefined;
    var services_count: usize = 0;

    // Find services attribute
    for (node.children.items) |attr_node| {
        switch (attr_node.kind) {
            .node => |nk| {
                if (nk == .NODE_ATTRPATH_VALUE) {
                    const attr_name = get_attrpath_name(attr_node, source) catch continue;
                    if (std.mem.eql(u8, attr_name, "services")) {
                        // Find list node
                        for (attr_node.children.items) |list_node| {
                            switch (list_node.kind) {
                                .node => |lnk| {
                                    if (lnk == .NODE_LIST) {
                                        // Extract each service
                                        for (list_node.children.items) |svc_node| {
                                            switch (svc_node.kind) {
                                                .node => |snk| {
                                                    if (snk == .NODE_ATTR_SET) {
                                                        if (services_count >= 64) return error.TooManyServices;
                                                        const service_id = try extract_field_u32(svc_node, source, "service_id");
                                                        const port = try extract_field_u16(svc_node, source, "port");
                                                        services_array[services_count] = scenario_mod.ServiceConfig.init(service_id, port);
                                                        services_count += 1;
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
                }
            },
            else => {},
        }
    }

    // Allocate and copy services
    const services = try allocator.alloc(scenario_mod.ServiceConfig, services_count);
    @memcpy(services, services_array[0..services_count]);
    return services;
}

/// Extract fault configuration
fn extract_fault_config(node: *nix.Node, source: []const u8) !fault_injector_mod.FaultConfig {
    var config = fault_injector_mod.FaultConfig{};

    // Find faults attribute
    for (node.children.items) |attr_node| {
        switch (attr_node.kind) {
            .node => |nk| {
                if (nk == .NODE_ATTRPATH_VALUE) {
                    const attr_name = get_attrpath_name(attr_node, source) catch continue;
                    if (std.mem.eql(u8, attr_name, "faults")) {
                        for (attr_node.children.items) |faults_node| {
                            switch (faults_node.kind) {
                                .node => |fnk| {
                                    if (fnk == .NODE_ATTR_SET) {
                                        config.crash_probability = extract_field_f64(faults_node, source, "crash_probability") catch 0.0;
                                        config.delay_probability = extract_field_f64(faults_node, source, "delay_probability") catch 0.0;
                                        config.delay_min_us = extract_field_u64(faults_node, source, "delay_min_us") catch 1000;
                                        config.delay_max_us = extract_field_u64(faults_node, source, "delay_max_us") catch 100_000;
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }

    return config;
}

// Helper functions for extracting typed values

fn extract_field_string(allocator: Allocator, node: *nix.Node, source: []const u8, field_name: []const u8) ![]const u8 {
    for (node.children.items) |attr_node| {
        switch (attr_node.kind) {
            .node => |nk| {
                if (nk == .NODE_ATTRPATH_VALUE) {
                    const attr_name = get_attrpath_name(attr_node, source) catch continue;
                    if (std.mem.eql(u8, attr_name, field_name)) {
                        for (attr_node.children.items) |val_node| {
                            switch (val_node.kind) {
                                .node => |vnk| {
                                    if (vnk == .NODE_STRING) {
                                        for (val_node.children.items) |token_node| {
                                            switch (token_node.kind) {
                                                .token => |tk| {
                                                    if (tk == .TOKEN_STRING_CONTENT) {
                                                        const str = source[token_node.start..token_node.end];
                                                        return allocator.dupe(u8, str);
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
                }
            },
            else => {},
        }
    }
    return error.FieldNotFound;
}

fn extract_field_u64(node: *nix.Node, source: []const u8, field_name: []const u8) !u64 {
    for (node.children.items) |attr_node| {
        switch (attr_node.kind) {
            .node => |nk| {
                if (nk == .NODE_ATTRPATH_VALUE) {
                    const attr_name = get_attrpath_name(attr_node, source) catch continue;
                    if (std.mem.eql(u8, attr_name, field_name)) {
                        for (attr_node.children.items) |val_node| {
                            switch (val_node.kind) {
                                .node => |vnk| {
                                    if (vnk == .NODE_LITERAL) {
                                        for (val_node.children.items) |token_node| {
                                            switch (token_node.kind) {
                                                .token => |tk| {
                                                    if (tk == .TOKEN_INTEGER) {
                                                        const int_str = source[token_node.start..token_node.end];
                                                        return try std.fmt.parseInt(u64, int_str, 10);
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
                }
            },
            else => {},
        }
    }
    return error.FieldNotFound;
}

fn extract_field_u32(node: *nix.Node, source: []const u8, field_name: []const u8) !u32 {
    const val = try extract_field_u64(node, source, field_name);
    return @intCast(val);
}

fn extract_field_u16(node: *nix.Node, source: []const u8, field_name: []const u8) !u16 {
    const val = try extract_field_u64(node, source, field_name);
    return @intCast(val);
}

fn extract_field_f64(node: *nix.Node, source: []const u8, field_name: []const u8) !f64 {
    for (node.children.items) |attr_node| {
        switch (attr_node.kind) {
            .node => |nk| {
                if (nk == .NODE_ATTRPATH_VALUE) {
                    const attr_name = get_attrpath_name(attr_node, source) catch continue;
                    if (std.mem.eql(u8, attr_name, field_name)) {
                        for (attr_node.children.items) |val_node| {
                            switch (val_node.kind) {
                                .node => |vnk| {
                                    if (vnk == .NODE_LITERAL) {
                                        for (val_node.children.items) |token_node| {
                                            switch (token_node.kind) {
                                                .token => |tk| {
                                                    if (tk == .TOKEN_FLOAT) {
                                                        const float_str = source[token_node.start..token_node.end];
                                                        return try std.fmt.parseFloat(f64, float_str);
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
                }
            },
            else => {},
        }
    }
    return error.FieldNotFound;
}

fn get_attrpath_name(node: *nix.Node, source: []const u8) ![]const u8 {
    // CST structure: NODE_ATTRPATH_VALUE -> NODE_ATTRPATH -> NODE_IDENT -> TOKEN_IDENT
    for (node.children.items) |child| {
        switch (child.kind) {
            .node => |nk| {
                if (nk == .NODE_ATTRPATH) {
                    // Look for NODE_IDENT inside NODE_ATTRPATH
                    for (child.children.items) |ident_node| {
                        switch (ident_node.kind) {
                            .node => |ink| {
                                if (ink == .NODE_IDENT) {
                                    // Find TOKEN_IDENT inside NODE_IDENT
                                    for (ident_node.children.items) |token_node| {
                                        switch (token_node.kind) {
                                            .token => |tk| {
                                                if (tk == .TOKEN_IDENT) {
                                                    return source[token_node.start..token_node.end];
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
    return error.AttributeNameNotFound;
}
