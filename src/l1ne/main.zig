const std = @import("std");
const cli = @import("cli.zig");
const types = @import("types.zig");
const master = @import("master.zig");
const systemd = @import("systemd.zig");

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();

    const gpa = arena_instance.allocator();
    const command = cli.parse_args(gpa);

    switch (command) {
        .start => |start| {
            std.log.info("Starting L1NE POC - deploying service instances...", .{});
            std.log.info("  Service: {s}", .{start.service});
            std.log.info("  Instances: {}", .{start.nodes.len});
            for (start.nodes.items[0..start.nodes.len], 0..) |node, i| {
                std.log.info("    Instance {}: {any}", .{ i + 1, node });
            }
            std.log.info("  State Dir: {s}", .{start.state_dir});

            // Initialize and start the master orchestrator
            var orchestrator = try master.Master.init(gpa, start);
            defer orchestrator.deinit();
            // Run the orchestrator (this blocks)
            try orchestrator.start(start);
        },
        .status => |status| {
            std.log.info("Querying L1NE service status...", .{});

            // List all L1NE services
            const services = try systemd.listL1neServices(gpa, true);
            defer {
                for (services) |service| {
                    gpa.free(service);
                }
                gpa.free(services);
            }

            if (services.len == 0) {
                std.debug.print("No L1NE services running\n", .{});
                return;
            }

            std.debug.print("\n=== L1NE Services Status ===\n\n", .{});

            for (services) |service_name| {
                // Query detailed status from systemd
                var service_status = systemd.queryServiceStatus(gpa, service_name, true) catch |err| {
                    std.debug.print("Service: {s}\n", .{service_name});
                    std.debug.print("  Error: Failed to query status ({any})\n\n", .{err});
                    continue;
                };
                defer service_status.deinit(gpa);

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
        .wal => |wal| {
            std.debug.print("Managing centralized logs...\n", .{});
            if (wal.node) |node| {
                std.debug.print("  Node: {any}\n", .{node});
            } else {
                std.debug.print("  Node: all\n", .{});
            }
            std.debug.print("  Lines: {d}\n", .{wal.lines});
            std.debug.print("  Follow: {any}\n", .{wal.follow});
            std.debug.print("  Path: {s}\n", .{wal.path});
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
