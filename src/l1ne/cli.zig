//! Parse and validate command-line arguments for the l1ne binary.
//!
//! Everything that can be validated without reading the data file must be validated here.
//! Caller must additionally assert validity of arguments as a defense in depth.
//!
//! Some flags are experimental: intentionally undocumented and are not a part of the official
//! surface area. Even experimental features must adhere to the same strict standard of safety,
//! but they come without any performance or usability guarantees.
//!
//! Experimental features are not gated by comptime option for safety: it is much easier to review
//! code for correctness when it is initially added to the main branch, rather when a comptime flag
//! is lifted.

const std = @import("std");
const assert = std.debug.assert;
const fmt = std.fmt;
const net = std.net;
const types = @import("types.zig");

const KIB = types.KIB;
const MIB = types.MIB;
const GIB = types.GIB;

const default_address = "127.0.0.1"; // POC only
const orchestrator_port = 42069; // Orchestrator control plane port
const max_nodes = 4; // POC: Maximum 4 service instances (like pods) on same server
// Services and ports come from CLI: --service=name --nodes=port1,port2,port3

// Generic validation configuration
const ValidationConfig = struct {
    flag: []const u8,
    min: ?u64 = null,
    max: ?u64 = null,
    alignment: ?u64 = null,
    required: bool = false,
};

// Generic validation function to reduce repetition
fn validate_range(value: anytype, config: ValidationConfig) @TypeOf(value) {
    const T = @TypeOf(value);
    const numeric_value = if (T == ByteSize) value.bytes() else value;

    if (config.min) |min| {
        if (numeric_value < min) {
            fatal("{s}: value {} is below minimum: {}", .{ config.flag, numeric_value, min });
        }
    }

    if (config.max) |max| {
        if (numeric_value > max) {
            fatal("{s}: value {} exceeds maximum: {}", .{ config.flag, numeric_value, max });
        }
    }

    if (config.alignment) |alignment| {
        if (numeric_value % alignment != 0) {
            fatal("{s}: value must be a multiple of {}", .{ config.flag, alignment });
        }
    }

    return value;
}

fn validate_percentage(value: u8, flag: []const u8) u8 {
    if (value == 0 or value > 100) {
        fatal("{s} must be between 1 and 100", .{flag});
    }
    return value;
}

const CLIArgs = union(enum) {
    const Start = struct {
        // Configuration loading: either from Nix file OR from CLI flags
        config: ?[]const u8 = null, // Path to Nix configuration file

        // Required when not using --config: service configuration
        service: []const u8,

        // Binary path and arguments to execute
        exec: []const u8, // Path to the binary to run

        // Nodes to deploy to (comma-separated addresses)
        pid_addresses: []const u8,

        // Optional orchestrator settings
        address: ?[]const u8 = null, // Bind address for control plane
        cache_size: ?ByteSize = null,

        // Resource limits - POC uses FAAS (Femboy-as-a-Service) percentages
        mem_percent: u8 = 50, // 1-100% of FAAS limit
        cpu_percent: u8 = 50, // 1-100% of FAAS limit

        development: bool = false,
        positional: struct {
            path: []const u8,
        },

        // Everything below here is considered experimental, and requires `--experimental` to be
        // set. Experimental flags disable automatic upgrades with multiversion binaries; each
        // replica has to be manually restarted.
        // Experimental flags must default to null, except for bools which must be false.
        experimental: bool = false,

        logger: bool = false,
        sre: bool = false,
        replica: ?u8 = null,
        max_replica: ?u8 = null,
        // because is a POC the CPU & memory maximun will be defined here dummy-service (FAAS: Femboy-as-a-Service)
        // and cpu_max & mem_max weill represent percentage of the maximum of the amount of the pre-limite defined inside o FAAS
        // data in percentage 1-100 of the FAAS limit not actually computer poc only
        mem_max: ?u8 = null,
        cpu_max: ?u8 = null,

        limit_storage: ?ByteSize = null,
        limit_pipeline_requests: ?u32 = null,
        limit_request: ?ByteSize = null,
        log_debug: bool = false,
        timeout_prepare_ms: ?u64 = null,
    };

    const Version = struct {
        verbose: bool = false,
    };

    const Benchmark = struct {
        logger_debugger: bool = false,
        target: ?[]const u8 = null,
        duration: u32 = 60,
        connections: u32 = 100,
        validate: bool = false,
        addresses: ?[]const u8 = null,
        seed: ?[]const u8 = null,
        log_debug: bool = false,
    };

    const Status = struct {
        node: ?[]const u8 = null, // Specific node or all
        service: []const u8 = "", // Service name
        format: []const u8 = "json", // Output format
    };

    // WAL for centralized logging from all nodes
    const WAL = struct {
        node: ?[]const u8 = null, // Filter by specific node
        slot: ?usize = null, // Specific log entry
        lines: u32 = 100,
        follow: bool = false,
        path: []const u8, // Path to WAL storage
    };

    const Simulate = struct {
        config: []const u8, // Path to scenario Nix file
        seed: ?u64 = null, // Optional seed override
        output: []const u8 = "text", // Output format: text or json
    };

    start: Start,
    status: Status,
    wal: WAL,
    simulate: Simulate,
    version: Version,
    benchmark: Benchmark,

    pub const help =
        \\l1ne - Service orchestrator
        \\
        \\Usage:
        \\  l1ne start [--config=FILE] DIR
        \\  l1ne simulate --config=FILE [--seed=N] [--output=FORMAT]
        \\  l1ne wal FILE [--lines=N] [--follow]
        \\  l1ne version
        \\
        \\Examples:
        \\  l1ne start .
        \\  l1ne start --config=src/l1ne/simulator/config/l1ne.nix .
        \\  l1ne simulate --config=src/l1ne/simulator/scenarios/chaos-test.nix
        \\  l1ne simulate --config=src/l1ne/simulator/scenarios/load-test.nix --seed=12345
        \\  l1ne wal l1ne.wal --lines=50
        \\  l1ne wal l1ne.wal --follow
        \\
    ;
};

pub const ByteSize = struct {
    value: u64,

    pub fn bytes(self: ByteSize) u64 {
        return self.value;
    }

    pub fn suffix(self: ByteSize) []const u8 {
        if (self.value >= GIB and self.value % GIB == 0) return "GiB";
        if (self.value >= MIB and self.value % MIB == 0) return "MiB";
        if (self.value >= KIB and self.value % KIB == 0) return "KiB";
        return "B";
    }
};

/// While CLIArgs store raw arguments as passed on the command line, Command ensures that arguments
/// are properly validated and desugared (e.g, sizes converted to counts where appropriate).
pub const Command = union(enum) {
    const Addresses = BoundedArray(std.net.Address, max_nodes);
    const Path = BoundedArray(u8, std.fs.max_path_bytes);

    pub const Start = struct {
        config_path: ?[]const u8, // Path to Nix configuration file (optional)
        service: []const u8, // Service name to deploy
        exec_path: []const u8, // Binary path to execute
        nodes: Addresses, // Nodes to deploy to (one service per node)
        bind: std.net.Address, // Control plane bind address
        mem_percent: u8, // FAAS memory percentage
        cpu_percent: u8, // FAAS CPU percentage
        state_dir: []const u8,
        development: bool,
        log_debug: bool,
        sre: bool,
    };

    pub const Status = struct {
        node: ?std.net.Address,
        service: []const u8,
        format: []const u8,
    };

    pub const WAL = struct {
        path: []const u8,
        node: ?std.net.Address,
        slot: ?usize,
        lines: u32,
        follow: bool,
    };

    pub const Version = struct {
        verbose: bool,
    };

    pub const Benchmark = struct {
        logger_debugger: bool,
        target: ?[]const u8,
        duration: u32,
        connections: u32,
        validate: bool,
        addresses: ?Addresses,
        seed: ?[]const u8,
        log_debug: bool,
    };

    pub const Simulate = struct {
        config_path: []const u8, // Path to scenario Nix file
        seed: ?u64, // Optional seed override
        output: []const u8, // Output format: "text" or "json"
    };

    start: Start,
    status: Status,
    wal: WAL,
    simulate: Simulate,
    version: Version,
    benchmark: Benchmark,
};

fn BoundedArray(comptime T: type, comptime capacity: usize) type {
    return struct {
        items: [capacity]T = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        pub fn push(self: *Self, item: T) !void {
            if (self.len >= capacity) return error.Overflow;
            self.items[self.len] = item;
            self.len += 1;
        }

        pub fn slice(self: *const Self) []const T {
            return self.items[0..self.len];
        }

        pub fn unused_capacity_slice(self: *Self) []T {
            return self.items[self.len..];
        }

        pub fn resize(self: *Self, new_len: usize) !void {
            if (new_len > capacity) return error.Overflow;
            self.len = new_len;
        }

        pub fn capacity_total(self: *const Self) usize {
            _ = self;
            return capacity;
        }
    };
}

/// Parse the command line arguments passed to the `l1ne` binary.
/// Exits the program with a non-zero exit code if an error is found.
pub fn parse_args(allocator: std.mem.Allocator) Command {
    var args = std.process.args();
    const cli_args = parse_cli_args(&args, allocator);

    return switch (cli_args) {
        .start => |start| .{ .start = parse_args_start(start) },
        .status => |status| .{ .status = parse_args_status(status) },
        .wal => |wal| .{ .wal = parse_args_wal(wal) },
        .simulate => |simulate| .{ .simulate = parse_args_simulate(simulate) },
        .version => |version| .{ .version = parse_args_version(version) },
        .benchmark => |benchmark| .{ .benchmark = parse_args_benchmark(benchmark) },
    };
}

fn parse_cli_args(args_iterator: anytype, allocator: std.mem.Allocator) CLIArgs {
    _ = allocator;
    _ = args_iterator.next(); // Skip program name

    const command_str = args_iterator.next() orelse {
        std.debug.print("{s}\n", .{CLIArgs.help});
        std.process.exit(0);
    };

    if (std.mem.eql(u8, command_str, "-h") or std.mem.eql(u8, command_str, "--help")) {
        std.debug.print("{s}\n", .{CLIArgs.help});
        std.process.exit(0);
    }

    if (std.mem.eql(u8, command_str, "start")) {
        return .{ .start = parse_start_args(args_iterator) };
    } else if (std.mem.eql(u8, command_str, "status")) {
        return .{ .status = parse_status_args(args_iterator) };
    } else if (std.mem.eql(u8, command_str, "wal")) {
        return .{ .wal = parse_wal_args(args_iterator) };
    } else if (std.mem.eql(u8, command_str, "simulate")) {
        return .{ .simulate = parse_simulate_args(args_iterator) };
    } else if (std.mem.eql(u8, command_str, "version")) {
        return .{ .version = parse_version_args(args_iterator) };
    } else if (std.mem.eql(u8, command_str, "benchmark")) {
        return .{ .benchmark = parse_benchmark_args(args_iterator) };
    } else {
        fatal("Unknown command: {s}", .{command_str});
    }
}

fn parse_status_args(args_iterator: anytype) CLIArgs.Status {
    var parser = GenericArgParser(CLIArgs.Status).init();

    while (args_iterator.next()) |arg| {
        if (parser.parseFlag(arg, "--node=", "node")) continue;
        // Additional status-specific flags can be added here
    }

    return parser.result;
}

fn parse_simulate_args(args_iterator: anytype) CLIArgs.Simulate {
    var parser = GenericArgParser(CLIArgs.Simulate).init();

    while (args_iterator.next()) |arg| {
        if (parser.parseFlag(arg, "--config=", "config")) continue;
        if (parser.parseFlag(arg, "--seed=", "seed")) continue;
        if (parser.parseFlag(arg, "--output=", "output")) continue;

        fatal("Unknown argument for simulate command: {s}", .{arg});
    }

    return parser.result;
}

fn parse_wal_args(args_iterator: anytype) CLIArgs.WAL {
    var parser = GenericArgParser(CLIArgs.WAL).init();

    while (args_iterator.next()) |arg| {
        if (parser.parseFlag(arg, "--node=", "node")) continue;
        if (parser.parseFlag(arg, "--slot=", "slot")) continue;
        if (parser.parseFlag(arg, "--lines=", "lines")) continue;

        if (std.mem.eql(u8, arg, "--follow") or std.mem.eql(u8, arg, "-f")) {
            parser.result.follow = true;
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            parser.result.path = arg;
        }
    }

    if (parser.result.path.len == 0) fatal("WAL path is required", .{});

    return parser.result;
}

fn GenericArgParser(comptime T: type) type {
    return struct {
        result: T,

        const Self = @This();

        pub fn init() Self {
            var result: T = undefined;

            // Initialize all fields with their defaults
            inline for (std.meta.fields(T)) |field| {
                if (field.default_value_ptr) |default_ptr| {
                    const default_value = @as(*const field.type, @ptrCast(@alignCast(default_ptr))).*;
                    @field(result, field.name) = default_value;
                } else {
                    // For fields without defaults, initialize based on type
                    @field(result, field.name) = switch (@typeInfo(field.type)) {
                        .optional => null,
                        .bool => false,
                        .int => 0,
                        .pointer => |ptr| if (ptr.size == .slice) "" else undefined,
                        else => undefined,
                    };
                }
            }

            return .{ .result = result };
        }

        pub fn parseFlag(self: *Self, arg: []const u8, comptime prefix: []const u8, comptime field_name: []const u8) bool {
            if (std.mem.startsWith(u8, arg, prefix)) {
                const field = std.meta.fieldInfo(T, @field(std.meta.FieldEnum(T), field_name));
                const value_str = arg[prefix.len..];

                switch (@typeInfo(field.type)) {
                    .optional => |opt| {
                        switch (@typeInfo(opt.child)) {
                            .int => |_| {
                                @field(self.result, field_name) = std.fmt.parseInt(opt.child, value_str, 10) catch {
                                    fatal("Invalid {s}: {s}", .{ field_name, value_str });
                                };
                            },
                            .pointer => |ptr| if (ptr.size == .slice) {
                                @field(self.result, field_name) = value_str;
                            } else unreachable,
                            else => {
                                if (opt.child == ByteSize) {
                                    @field(self.result, field_name) = parse_byte_size(value_str);
                                }
                            },
                        }
                    },
                    .int => |_| {
                        @field(self.result, field_name) = std.fmt.parseInt(field.type, value_str, 10) catch {
                            fatal("Invalid {s}: {s}", .{ field_name, value_str });
                        };
                    },
                    .pointer => |ptr| if (ptr.size == .slice) {
                        @field(self.result, field_name) = value_str;
                    } else unreachable,
                    else => unreachable,
                }
                return true;
            }
            return false;
        }
    };
}

fn parse_start_args(args_iterator: anytype) CLIArgs.Start {
    var parser = GenericArgParser(CLIArgs.Start).init();

    while (args_iterator.next()) |arg| {
        // Use comptime-generated parsing for common patterns
        if (parser.parseFlag(arg, "--config=", "config")) continue;
        if (parser.parseFlag(arg, "--service=", "service")) continue;
        if (parser.parseFlag(arg, "--exec=", "exec")) continue;
        if (parser.parseFlag(arg, "--cache-size=", "cache_size")) continue;
        if (parser.parseFlag(arg, "--limit-storage=", "limit_storage")) continue;
        if (parser.parseFlag(arg, "--limit-request=", "limit_request")) continue;
        if (parser.parseFlag(arg, "--limit-pipeline-requests=", "limit_pipeline_requests")) continue;
        if (parser.parseFlag(arg, "--timeout-prepare-ms=", "timeout_prepare_ms")) continue;

        // Handle special cases that need custom logic
        if (std.mem.startsWith(u8, arg, "--nodes=") or std.mem.startsWith(u8, arg, "--pid-addresses=")) {
            const prefix_len = if (std.mem.startsWith(u8, arg, "--nodes=")) "--nodes=".len else "--pid-addresses=".len;
            parser.result.pid_addresses = arg[prefix_len..];
        } else if (std.mem.startsWith(u8, arg, "--address=") or std.mem.startsWith(u8, arg, "--bind=")) {
            const prefix_len = if (std.mem.startsWith(u8, arg, "--bind=")) "--bind=".len else "--address=".len;
            parser.result.address = arg[prefix_len..];
        } else if (std.mem.eql(u8, arg, "--logger")) {
            parser.result.logger = true;
        } else if (std.mem.eql(u8, arg, "--sre")) {
            parser.result.sre = true;
        } else if (parser.parseFlag(arg, "--replica=", "replica")) {
            // Handled by parseFlag
        } else if (parser.parseFlag(arg, "--max-replica=", "max_replica")) {
            // Handled by parseFlag
        } else if (std.mem.startsWith(u8, arg, "--mem-max=") or std.mem.startsWith(u8, arg, "--mem-percent=")) {
            const is_percent = std.mem.startsWith(u8, arg, "--mem-percent=");
            const prefix_len = if (is_percent) "--mem-percent=".len else "--mem-max=".len;
            const value_str = arg[prefix_len..];
            const field_name = if (is_percent) "mem_percent" else "mem_max";
            const val = std.fmt.parseInt(u8, value_str, 10) catch {
                fatal("Invalid {s}: {s}", .{ field_name, value_str });
            };
            if (is_percent) {
                parser.result.mem_percent = val;
            } else {
                parser.result.mem_max = val;
            }
        } else if (std.mem.startsWith(u8, arg, "--cpu-max=") or std.mem.startsWith(u8, arg, "--cpu-percent=")) {
            const is_percent = std.mem.startsWith(u8, arg, "--cpu-percent=");
            const prefix_len = if (is_percent) "--cpu-percent=".len else "--cpu-max=".len;
            const value_str = arg[prefix_len..];
            const field_name = if (is_percent) "cpu_percent" else "cpu_max";
            const val = std.fmt.parseInt(u8, value_str, 10) catch {
                fatal("Invalid {s}: {s}", .{ field_name, value_str });
            };
            if (is_percent) {
                parser.result.cpu_percent = val;
            } else {
                parser.result.cpu_max = val;
            }
        } else if (std.mem.eql(u8, arg, "--experimental")) {
            parser.result.experimental = true;
        } else if (std.mem.eql(u8, arg, "--development")) {
            parser.result.development = true;
        } else if (std.mem.eql(u8, arg, "--log-debug")) {
            parser.result.log_debug = true;
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            parser.result.positional.path = arg;
        }
    }

    // Validate: either --config OR (--service + --exec + --pid-addresses)
    const has_config = parser.result.config != null;
    const has_cli_config = parser.result.service.len > 0 or
        parser.result.exec.len > 0 or
        parser.result.pid_addresses.len > 0;

    if (!has_config and !has_cli_config) {
        fatal("Either --config or (--service + --exec + --pid-addresses) is required", .{});
    }

    if (has_config and has_cli_config) {
        fatal("Cannot use both --config and CLI flags (--service, --exec, --pid-addresses)", .{});
    }

    // When using CLI flags, all are required
    if (!has_config) {
        if (parser.result.service.len == 0) {
            fatal("--service is required when not using --config", .{});
        }
        if (parser.result.exec.len == 0) {
            fatal("--exec is required when not using --config", .{});
        }
        if (parser.result.pid_addresses.len == 0) {
            fatal("--nodes (or --pid-addresses) is required when not using --config", .{});
        }
    }

    // When using --config, validate the path
    if (has_config) {
        const config_path = parser.result.config.?;
        if (config_path.len == 0) {
            fatal("--config path cannot be empty", .{});
        }
        if (!std.mem.endsWith(u8, config_path, ".nix")) {
            fatal("--config must point to a .nix file", .{});
        }
    }

    if (parser.result.positional.path.len == 0) {
        fatal("Missing required data file path", .{});
    }

    return parser.result;
}

fn parse_version_args(args_iterator: anytype) CLIArgs.Version {
    var parser = GenericArgParser(CLIArgs.Version).init();

    while (args_iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, "--verbose")) {
            parser.result.verbose = true;
        }
    }

    return parser.result;
}

fn parse_benchmark_args(args_iterator: anytype) CLIArgs.Benchmark {
    var parser = GenericArgParser(CLIArgs.Benchmark).init();

    while (args_iterator.next()) |arg| {
        if (parser.parseFlag(arg, "--target=", "target")) continue;
        if (parser.parseFlag(arg, "--duration=", "duration")) continue;
        if (parser.parseFlag(arg, "--connections=", "connections")) continue;
        if (parser.parseFlag(arg, "--addresses=", "addresses")) continue;
        if (parser.parseFlag(arg, "--seed=", "seed")) continue;

        if (std.mem.eql(u8, arg, "--validate")) {
            parser.result.validate = true;
        } else if (std.mem.eql(u8, arg, "--logger-debugger")) {
            parser.result.logger_debugger = true;
        } else if (std.mem.eql(u8, arg, "--log-debug")) {
            parser.result.log_debug = true;
        }
    }

    return parser.result;
}

fn parse_args_status(status: CLIArgs.Status) Command.Status {
    return .{
        .node = if (status.node) |n| parse_address_and_port(n, "--node", orchestrator_port) else null,
        .service = status.service,
        .format = status.format,
    };
}

fn parse_args_wal(wal: CLIArgs.WAL) Command.WAL {
    return .{
        .path = wal.path,
        .node = if (wal.node) |n| parse_address_and_port(n, "--node", orchestrator_port) else null,
        .slot = wal.slot,
        .lines = wal.lines,
        .follow = wal.follow,
    };
}

fn parse_args_simulate(simulate: CLIArgs.Simulate) Command.Simulate {
    // Validate required arguments
    if (simulate.config.len == 0) {
        fatal("simulate command requires --config=FILE argument", .{});
    }

    if (!std.mem.endsWith(u8, simulate.config, ".nix")) {
        fatal("config file must have .nix extension: {s}", .{simulate.config});
    }

    // Validate output format
    const valid_output = std.mem.eql(u8, simulate.output, "text") or
        std.mem.eql(u8, simulate.output, "json");
    if (!valid_output) {
        fatal("--output must be 'text' or 'json', got: {s}", .{simulate.output});
    }

    return .{
        .config_path = simulate.config,
        .seed = simulate.seed,
        .output = simulate.output,
    };
}

// Validate experimental flags using comptime
fn validateExperimentalFlags(start: CLIArgs.Start) void {
    const stable_args = .{
        "service",      "pid_addresses",
        "address",      "cache_size",
        "mem_percent",  "cpu_percent",
        "positional",   "development",
        "experimental",
    };

    inline for (std.meta.fields(@TypeOf(start))) |field| {
        @setEvalBranchQuota(10_000);
        const stable_field = comptime for (stable_args) |stable_arg| {
            assert(std.meta.fieldIndex(@TypeOf(start), stable_arg) != null);
            if (std.mem.eql(u8, field.name, stable_arg)) {
                break true;
            }
        } else false;

        if (stable_field) continue;

        const flag_name = comptime blk: {
            var result: [2 + field.name.len]u8 = ("--" ++ field.name).*;
            std.mem.replaceScalar(u8, &result, '_', '-');
            break :blk result;
        };

        // Runtime check: if experimental field is set, require --experimental flag
        if (field.type == bool) {
            if (@field(start, field.name) and !start.experimental) {
                fatal("{s} is marked experimental, add `--experimental` to continue.", .{flag_name});
            }
        } else if (@typeInfo(field.type) == .optional) {
            if (@field(start, field.name) != null and !start.experimental) {
                fatal("{s} is marked experimental, add `--experimental` to continue.", .{flag_name});
            }
        }
    }
}

fn parse_args_start(start: CLIArgs.Start) Command.Start {
    validateExperimentalFlags(start);

    // When using --config, provide dummy values for required CLI fields
    // main.zig will ignore these and use config from file
    const addresses = if (start.config != null)
        Command.Addresses.init()
    else
        parse_addresses(start.pid_addresses, "--pid-addresses");

    // Use generic validators for limits
    const storage_limit = validate_range(
        start.limit_storage orelse ByteSize{ .value = 10 * GIB },
        .{
            .flag = "--limit-storage",
            .min = 64 * MIB,
            .max = 1024 * GIB,
            .alignment = 512,
        },
    );

    const pipeline_limit = validate_range(
        start.limit_pipeline_requests orelse @as(u32, 100),
        .{
            .flag = "--limit-pipeline-requests",
            .min = 0,
            .max = 1024,
        },
    );

    const request_limit = validate_range(
        if (start.limit_request) |rl| @as(u32, @intCast(rl.bytes())) else @as(u32, 1 * MIB),
        .{
            .flag = "--limit-request",
            .min = 4096,
            .max = 1 * MIB,
        },
    );

    // Validate percentages
    const mem_percent = validate_percentage(start.mem_percent, "--mem-percent");
    const cpu_percent = validate_percentage(start.cpu_percent, "--cpu-percent");

    _ = storage_limit;
    _ = pipeline_limit;
    _ = request_limit;

    const parsed_address = if (start.address) |addr|
        parse_address_and_port(addr, "--address", orchestrator_port)
    else
        parse_address_and_port("0.0.0.0", "--address", orchestrator_port);

    return .{
        .config_path = start.config,
        .service = start.service,
        .exec_path = start.exec,
        .nodes = addresses,
        .bind = parsed_address,
        .mem_percent = mem_percent,
        .cpu_percent = cpu_percent,
        .state_dir = start.positional.path,
        .development = start.development,
        .log_debug = start.log_debug,
        .sre = start.sre,
    };
}

fn parse_args_version(version: CLIArgs.Version) Command.Version {
    return .{
        .verbose = version.verbose,
    };
}

fn parse_args_benchmark(benchmark: CLIArgs.Benchmark) Command.Benchmark {
    const addresses = if (benchmark.addresses) |addr|
        parse_addresses(addr, "--addresses")
    else
        null;

    return .{
        .logger_debugger = benchmark.logger_debugger,
        .target = benchmark.target,
        .duration = benchmark.duration,
        .connections = benchmark.connections,
        .validate = benchmark.validate,
        .addresses = addresses,
        .seed = benchmark.seed,
        .log_debug = benchmark.log_debug,
    };
}

fn parse_addresses(raw_addresses: []const u8, comptime flag: []const u8) Command.Addresses {
    comptime assert(std.mem.startsWith(u8, flag, "--"));
    var result = Command.Addresses.init();
    var iter = std.mem.tokenizeScalar(u8, raw_addresses, ',');

    while (iter.next()) |addr_str| {
        const addr = parse_address_and_port(addr_str, flag, orchestrator_port);

        // Check for duplicate addresses
        for (result.slice()) |existing_addr| {
            if (std.net.Address.eql(existing_addr, addr)) {
                fatal("{s}: duplicate node address detected: {s}", .{ flag, addr_str });
            }
        }

        result.push(addr) catch {
            fatal("{s}: too many addresses, at most {} are allowed", .{ flag, max_nodes });
        };
    }

    if (result.len == 0) {
        fatal("{s}: at least one address is required", .{flag});
    }

    return result;
}

fn parse_address_and_port(raw_address: []const u8, comptime flag: []const u8, port_default: u16) std.net.Address {
    comptime assert(std.mem.startsWith(u8, flag, "--"));

    var addr_str = raw_address;
    var port: u16 = port_default;

    // Check for IPv6 format [::1]:port
    if (std.mem.startsWith(u8, addr_str, "[")) {
        const close_bracket = std.mem.indexOf(u8, addr_str, "]") orelse {
            fatal("{s}: invalid IPv6 address format", .{flag});
        };
        const ipv6_str = addr_str[1..close_bracket];
        if (close_bracket + 1 < addr_str.len and addr_str[close_bracket + 1] == ':') {
            const port_str = addr_str[close_bracket + 2 ..];
            port = std.fmt.parseInt(u16, port_str, 10) catch {
                fatal("{s}: invalid port: {s}", .{ flag, port_str });
            };
        }
        addr_str = ipv6_str;
    } else if (std.mem.lastIndexOf(u8, addr_str, ":")) |colon_pos| {
        const port_str = addr_str[colon_pos + 1 ..];
        port = std.fmt.parseInt(u16, port_str, 10) catch {
            // Try to parse as just port number
            if (std.fmt.parseInt(u16, addr_str, 10)) |port_only| {
                return std.net.Address.parseIp(default_address, port_only) catch {
                    fatal("{s}: invalid address or port: {s}", .{ flag, addr_str });
                };
            } else |_| {
                fatal("{s}: invalid port: {s}", .{ flag, port_str });
            }
        };
        addr_str = addr_str[0..colon_pos];
    } else {
        // Try to parse as just port number
        if (std.fmt.parseInt(u16, addr_str, 10)) |port_only| {
            return std.net.Address.parseIp(default_address, port_only) catch {
                fatal("{s}: invalid address: {s}", .{ flag, addr_str });
            };
        } else |_| {}
    }

    const address = std.net.Address.parseIp(addr_str, port) catch {
        fatal("{s}: invalid IP address: {s}", .{ flag, addr_str });
    };

    return address;
}

fn parse_byte_size(str: []const u8) ByteSize {
    var value: u64 = 0;
    var suffix_start: usize = 0;

    for (str, 0..) |c, i| {
        if (c >= '0' and c <= '9') {
            value = value * 10 + (c - '0');
            suffix_start = i + 1;
        } else {
            break;
        }
    }

    const suffix = str[suffix_start..];
    const multiplier: u64 = if (std.mem.eql(u8, suffix, "KiB"))
        KIB
    else if (std.mem.eql(u8, suffix, "MiB"))
        MIB
    else if (std.mem.eql(u8, suffix, "GiB"))
        GIB
    else if (suffix.len == 0 or std.mem.eql(u8, suffix, "B"))
        1
    else
        fatal("Invalid size suffix: {s}", .{suffix});

    return .{ .value = value * multiplier };
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("Error: " ++ format ++ "\n", args);
    std.process.exit(1);
}

// CLIArgs store RAW data from user, desugared in compilers means transform human-friendly to machine-friendly
// convert user raw inputs to system types and validate at comptime type shit
pub const DesugaredArgs = union(enum) {};

comptime {
    // Validate that all struct fields have proper defaults
    assert(@sizeOf(CLIArgs.Start) > 0);
    // assert(@sizeOf(CLIArgs.Format) > 0); // Format removed
    assert(@sizeOf(CLIArgs.Version) > 0);
    assert(@sizeOf(CLIArgs.Benchmark) > 0);
    // Validate help text compiles
    _ = CLIArgs.help;
}
