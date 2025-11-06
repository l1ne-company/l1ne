const std = @import("std");
const assert = std.debug.assert;
const cli = @import("cli.zig");
const types = @import("types.zig");
const master = @import("master.zig");
const systemd = @import("systemd.zig");
const config_mod = @import("config.zig");
const static_allocator_mod = @import("static_allocator.zig");
const constants = @import("constants.zig");
const wal = @import("wal.zig");
const scenario_config_mod = @import("scenario_config.zig");
const scenario_mod = @import("scenario.zig");
const metrics_mod = @import("metrics.zig");
const verification_mod = @import("verification.zig");

/// Run WAL command (read and display WAL entries)
///
/// Invariants:
///   - Pre: wal_cmd is valid
///   - Pre: wal_cmd.path is non-empty
///   - Pre: wal_cmd.lines > 0
///   - Post: WAL file read and entries displayed
fn run_wal_command(wal_cmd: cli.Command.WAL) !void {
    assert(wal_cmd.path.len > 0); // Path must be non-empty
    assert(wal_cmd.lines > 0); // Must read at least one line

    // Open WAL file
    const file = try std.fs.cwd().openFile(wal_cmd.path, .{});
    defer file.close();

    // Create WAL reader
    var reader = wal.Reader.init(file);
    assert(reader.entries_read == 0); // Initial state

    std.debug.print("Reading WAL: {s}\n", .{wal_cmd.path});
    if (wal_cmd.node) |node| {
        std.debug.print("Filtering by node: {any}\n", .{node});
    }
    std.debug.print("Showing up to {d} entries\n\n", .{wal_cmd.lines});

    // Read entries up to limit
    var count: u32 = 0;
    while (count < wal_cmd.lines) : (count += 1) {
        var entry: wal.Entry = undefined;
        const result = try reader.read_entry(&entry);

        // Check for EOF
        if (result == null) {
            break;
        }

        assert(entry.verify_crc32()); // CRC must be valid

        // Display entry
        print_wal_entry(&entry, count + 1);
    }

    assert(reader.entries_read == count); // Count must match
    std.debug.print("\nRead {d} entries\n", .{count});

    if (wal_cmd.follow) {
        std.debug.print("Follow mode not yet implemented\n", .{});
    }
}

/// Print WAL entry in human-readable format
///
/// Invariants:
///   - Pre: entry is valid pointer
///   - Pre: entry CRC is valid
///   - Pre: index > 0
fn print_wal_entry(entry: *const wal.Entry, index: u32) void {
    assert(@intFromPtr(entry) != 0); // Entry must be valid
    assert(entry.verify_crc32()); // CRC must be valid
    assert(index > 0); // Index must be positive

    const type_name = switch (entry.entry_type) {
        .service_start => "ServiceStart",
        .service_stop => "ServiceStop",
        .proxy_accept => "ProxyAccept",
        .proxy_close => "ProxyClose",
        .config_reload => "ConfigReload",
        .checkpoint => "Checkpoint",
        .tx_begin => "TxBegin",
        .tx_commit => "TxCommit",
        .tx_abort => "TxAbort",
    };

    std.debug.print("[{d:4}] {s:15} @ {d:12} us", .{
        index,
        type_name,
        entry.timestamp_us,
    });

    // Print payload details based on type
    switch (entry.entry_type) {
        .service_start => {
            const payload: *const wal.ServiceStartPayload = @ptrCast(@alignCast(&entry.payload));
            std.debug.print(" | service_id={d} port={d}\n", .{
                payload.service_id,
                payload.port,
            });
        },
        .service_stop => {
            const payload: *const wal.ServiceStopPayload = @ptrCast(@alignCast(&entry.payload));
            std.debug.print(" | service_id={d} exit_code={d}\n", .{
                payload.service_id,
                payload.exit_code,
            });
        },
        .proxy_accept => {
            const payload: *const wal.ProxyAcceptPayload = @ptrCast(@alignCast(&entry.payload));
            std.debug.print(" | conn={d} service_id={d} port={d}\n", .{
                payload.connection_id,
                payload.service_id,
                payload.client_port,
            });
        },
        .proxy_close => {
            const payload: *const wal.ProxyClosePayload = @ptrCast(@alignCast(&entry.payload));
            std.debug.print(" | conn={d} sent={d} recv={d}\n", .{
                payload.connection_id,
                payload.bytes_sent,
                payload.bytes_received,
            });
        },
        .config_reload, .checkpoint => {
            std.debug.print("\n", .{});
        },
        .tx_begin, .tx_commit, .tx_abort => {
            std.debug.print("\n", .{});
        },
    }
}

/// Run simulate command (execute scenario simulation)
///
/// Invariants:
///   - Pre: allocator is valid
///   - Pre: sim.config_path is non-empty
///   - Post: scenario executed and results displayed
fn run_simulate_command(allocator: std.mem.Allocator, sim: cli.Command.Simulate) !void {
    assert(@intFromPtr(allocator.ptr) != 0); // Allocator must be valid
    assert(sim.config_path.len > 0); // Config path must be non-empty

    std.debug.print("Loading scenario: {s}\n", .{sim.config_path});

    // Load scenario config from Nix file
    var scenario_config = try scenario_config_mod.ScenarioConfig.from_nix_file(
        allocator,
        sim.config_path,
    );
    defer scenario_config.deinit();

    // Override seed if provided
    const seed = sim.seed orelse scenario_config.seed;

    std.debug.print("\n=== Scenario Configuration ===\n", .{});
    std.debug.print("  Name: {s}\n", .{scenario_config.name});
    std.debug.print("  Type: {s}\n", .{@tagName(scenario_config.scenario_type)});
    std.debug.print("  Duration: {d} us\n", .{scenario_config.duration_us});
    std.debug.print("  Seed: {d}\n", .{seed});
    std.debug.print("  Services: {d}\n", .{scenario_config.services.len});
    std.debug.print("  Faults:\n", .{});
    std.debug.print("    Crash probability: {d:.2}\n", .{scenario_config.fault_config.crash_probability});
    std.debug.print("    Delay probability: {d:.2}\n", .{scenario_config.fault_config.delay_probability});
    std.debug.print("\n", .{});

    // Build ScenarioConfig for runner
    var runner_config = scenario_mod.ScenarioConfig.init(
        scenario_config.name,
        scenario_config.scenario_type,
    );
    runner_config.duration_us = scenario_config.duration_us;
    runner_config.seed = seed;
    runner_config.fault_config = scenario_config.fault_config;

    // Add services
    for (scenario_config.services) |service| {
        try runner_config.add_service(service.service_id, service.port);
    }

    assert(runner_config.service_count > 0); // Must have services
    assert(runner_config.duration_us > 0); // Must have duration

    // Initialize runner
    std.debug.print("Initializing scenario runner...\n", .{});
    var runner = scenario_mod.ScenarioRunner.init(runner_config, seed);

    // Run scenario
    std.debug.print("Running scenario...\n\n", .{});
    const result = try runner.run();

    // Display results
    const is_json = std.mem.eql(u8, sim.output, "json");
    if (is_json) {
        print_simulation_results_json(&result);
    } else {
        print_simulation_results_text(&result);
    }
}

/// Print simulation results in text format
///
/// Invariants:
///   - Pre: result is valid pointer
fn print_simulation_results_text(result: *const scenario_mod.ScenarioResult) void {
    assert(@intFromPtr(result) != 0); // Result must be valid

    std.debug.print("=== Simulation Results ===\n", .{});
    std.debug.print("Status: {s}\n", .{if (result.success) "SUCCESS" else "FAILED"});
    std.debug.print("\nMetrics:\n", .{});
    std.debug.print("  Events processed: {d}\n", .{result.events_processed});
    std.debug.print("  Faults injected: {d}\n", .{result.faults_injected});
    std.debug.print("  Services started: {d}\n", .{result.services_started});
    std.debug.print("  Services stopped: {d}\n", .{result.services_stopped});
    std.debug.print("  Duration: {d} us\n", .{result.duration_us});

    if (result.error_message) |err_msg| {
        std.debug.print("\nError: {s}\n", .{err_msg});
    }
}

/// Print simulation results in JSON format
///
/// Invariants:
///   - Pre: result is valid pointer
fn print_simulation_results_json(result: *const scenario_mod.ScenarioResult) void {
    assert(@intFromPtr(result) != 0); // Result must be valid

    var buffer: [4096]u8 = undefined;
    const stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&buffer);
    std.json.Stringify.value(result.*, .{ .whitespace = .indent_2 }, &stdout_writer.interface) catch |err| {
        std.debug.print("Failed to serialize JSON: {any}\n", .{err});
        return;
    };
    stdout_writer.interface.flush() catch {};
    std.debug.print("\n", .{});
}

pub fn main() !void {
    // ============================================================
    // PHASE 1: INIT - Dynamic allocation to construct initial state
    // ============================================================

    std.log.info("=== L1NE Initialization ===", .{});
    std.log.info("Zig version: {any}", .{@import("builtin").zig_version});
    std.log.info("Build mode: {any}", .{@import("builtin").mode});

    // Initialize static allocator in INIT mode
    var static_allocator = static_allocator_mod.StaticAllocator.init(std.heap.page_allocator);
    const allocator = static_allocator.allocator();

    // Parse CLI arguments (still needed for some commands)
    const command = cli.parse_args(allocator);

    switch (command) {
        .start => |start| {
            assert(@intFromPtr(allocator.ptr) != 0); // Allocator must be valid
            assert(start.state_dir.len > 0); // State dir must be non-empty

            std.log.info("Starting L1NE orchestrator", .{});
            std.log.info("State directory: {s}", .{start.state_dir});

            // Load configuration from required Nix file
            const config_path = start.config_path orelse {
                std.log.err("`l1ne start` now requires --config pointing to a Nix file", .{});
                return error.ConfigRequired;
            };
            assert(config_path.len > 0); // Config path must be non-empty
            assert(std.mem.endsWith(u8, config_path, ".nix")); // Must be .nix file

            std.log.info("Loading configuration from Nix file: {s}", .{config_path});

            var config = config_mod.Config.from_nix_file(allocator, config_path) catch |err| {
                std.log.err("Failed to load config from {s}: {any}", .{ config_path, err });
                return err;
            };
            defer config.deinit();

            // Validate configuration
            try config.limits.validate();

            std.log.info("Configuration loaded successfully", .{});
            std.log.info("  Services: {any}", .{config.services.len});
            std.log.info("  Proxy connections max: {any}", .{config.limits.proxy_connections_max});
            std.log.info("  Proxy buffer size: {any} KiB", .{config.limits.proxy_buffer_size / types.KIB});

            // Initialize master orchestrator with runtime limits
            var orchestrator = try master.Master.init(allocator, config.limits, start.bind);
            defer orchestrator.deinit();

            // ============================================================
            // PHASE 2: STATIC - Lock allocator, run with bounded memory
            // ============================================================

            std.log.info("", .{});
            std.log.info("=== Transitioning to Static Mode ===", .{});

            // This is the critical transition: no more allocation allowed after this
            static_allocator.transition_to_static();

            assert(static_allocator.is_static()); // Must be in static mode
            std.log.info("Memory is now LOCKED", .{});
            std.log.info("Running with bounded resources", .{});
            std.log.info("", .{});

            // Run the orchestrator forever with bounded memory
            // Any attempt to allocate will panic
            try orchestrator.start(config);
        },
        .status => |status| {
            std.log.info("Querying L1NE service status...", .{});

            // List all L1NE services
            const services = try systemd.listL1neServices(allocator, true);
            defer {
                for (services) |service| {
                    allocator.free(service);
                }
                allocator.free(services);
            }

            if (services.len == 0) {
                std.debug.print("No L1NE services running\n", .{});
                return;
            }

            std.debug.print("\n=== L1NE Services Status ===\n\n", .{});

            for (services) |service_name| {
                // Query detailed status from systemd
                var service_status = systemd.queryServiceStatus(allocator, service_name, true) catch |err| {
                    std.debug.print("Service: {s}\n", .{service_name});
                    std.debug.print("  Error: Failed to query status ({any})\n\n", .{err});
                    continue;
                };
                defer service_status.deinit(allocator);

                // Print service information
                std.debug.print("Service: {s}\n", .{service_name});
                std.debug.print("  Description: {s}\n", .{service_status.description});
                std.debug.print("  Load State: {s}\n", .{service_status.load_state});
                std.debug.print("  Active State: {s}\n", .{service_status.active_state});
                std.debug.print("  Sub State: {s}\n", .{service_status.sub_state});

                if (service_status.main_pid) |pid| {
                    std.debug.print("  Main PID: {d}\n", .{pid});
                }

                if (service_status.memory_current) |mem| {
                    const mem_mb = @as(f64, @floatFromInt(mem)) / (types.MIB);
                    std.debug.print("  Memory: {d:.2} MiB\n", .{mem_mb});
                }

                if (service_status.cpu_usage_nsec) |cpu_nsec| {
                    const cpu_sec = @as(f64, @floatFromInt(cpu_nsec)) / types.SEC;
                    std.debug.print("  CPU Time: {d:.2} seconds\n", .{cpu_sec});
                }

                std.debug.print("\n", .{});
            }

            _ = status; // Suppress unused warning
        },
        .wal => |wal_cmd| {
            try run_wal_command(wal_cmd);
        },
        .simulate => |sim| {
            try run_simulate_command(allocator, sim);
        },
        .version => |version| {
            std.debug.print("L1NE v0.0.1\n", .{});
            if (version.verbose) {
                std.debug.print("Compile-time configuration:\n", .{});
                std.debug.print("  Build mode: {}\n", .{@import("builtin").mode});
            }
        },
        .benchmark => |benchmark| {
            std.debug.print("Running benchmark...\n", .{});
            std.debug.print("  Duration: {} seconds\n", .{benchmark.duration});
            std.debug.print("  Connections: {}\n", .{benchmark.connections});
            if (benchmark.target) |target| {
                std.debug.print("  Target: {s}\n", .{target});
            }
        },
    }
}
