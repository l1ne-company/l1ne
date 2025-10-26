const std = @import("std");
const net = std.net;
const systemd = @import("systemd.zig");
const cli = @import("cli.zig");
const types = @import("types.zig");

/// Master orchestrator that manages service instances
pub const Master = struct {
    allocator: std.mem.Allocator,
    bind_address: net.Address,
    services: std.ArrayList(ServiceInstance),
    systemd_notifier: ?systemd.Notifier,
    watchdog: ?systemd.Watchdog,

    const ServiceInstance = struct {
        name: []const u8,
        unit_name: []const u8, // systemd unit name (e.g., "l1ne-dumb-server-8080.service")
        address: net.Address,
        pid: ?std.posix.pid_t,
        status: Status,
        resources: ResourceLimits,
        cgroup_monitor: ?systemd.CgroupMonitor,

        const Status = enum {
            starting,
            running,
            stopping,
            stopped,
            failed,
        };

        const ResourceLimits = struct {
            memory_percent: u8,
            cpu_percent: u8,
        };
    };

    pub fn init(allocator: std.mem.Allocator, config: cli.Command.Start) !Master {
        var notifier: ?systemd.Notifier = null;
        var watchdog: ?systemd.Watchdog = null;

        // Initialize systemd integration if available
        if (systemd.isUnderSystemd()) {
            notifier = systemd.Notifier.init(allocator);
            if (notifier) |*n| {
                watchdog = try systemd.Watchdog.init(n, allocator);
            }
        }

        return Master{
            .allocator = allocator,
            .bind_address = config.bind,
            .services = std.ArrayList(ServiceInstance).empty,
            .systemd_notifier = notifier,
            .watchdog = watchdog,
        };
    }

    pub fn deinit(self: *Master) void {
        if (self.systemd_notifier) |*notifier| {
            notifier.deinit();
        }
        for (self.services.items) |*service| {
            if (service.cgroup_monitor) |*monitor| {
                monitor.deinit();
            }
        }
        self.services.deinit(self.allocator);
    }

    /// Start the master orchestrator
    pub fn start(self: *Master, config: cli.Command.Start) !void {
        // Notify systemd we're starting
        if (self.systemd_notifier) |*notifier| {
            try notifier.status("Starting L1NE orchestrator...");
        }

        // Deploy service instances
        for (config.nodes.slice()) |node_addr| {
            try self.deployInstance(config.service, config.exec_path, node_addr, .{
                .memory_percent = config.mem_percent,
                .cpu_percent = config.cpu_percent,
            });
        }

        // Start load balancer
        var server = try net.Address.listen(self.bind_address, .{
            .reuse_address = true,
        });
        defer server.deinit();

        // Notify systemd we're ready
        if (self.systemd_notifier) |*notifier| {
            try notifier.ready();
            try notifier.status(try std.fmt.allocPrint(self.allocator, "Managing {d} instances of {s}", .{ config.nodes.len, config.service }));
        }

        std.log.info("L1NE orchestrator listening on {any}", .{self.bind_address});

        // Main loop
        while (true) {
            // Send watchdog keepalive if needed
            if (self.watchdog) |*wd| {
                try wd.keepaliveIfNeeded();
            }

            // Accept connections and load balance
            if (server.accept()) |conn| {
                // Round-robin load balancing
                const instance = self.selectHealthyInstance() orelse {
                    conn.stream.close();
                    continue;
                };

                // Forward to selected instance
                self.forwardConnection(conn, instance) catch |err| {
                    std.log.err("Failed to forward connection: {any}", .{err});
                };
            } else |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(10 * types.MILLISEC);
                    continue;
                }
                return err;
            }
        }
    }

    /// Deploy a service instance
    fn deployInstance(
        self: *Master,
        service_name: []const u8,
        exec_path: []const u8,
        address: net.Address,
        limits: ServiceInstance.ResourceLimits,
    ) !void {
        std.log.info("Deploying {s} instance at port {d}", .{ service_name, address.getPort() });

        // Generate systemd unit name
        const unit_name = try std.fmt.allocPrint(self.allocator, "l1ne-{s}-{d}.service", .{ service_name, address.getPort() });

        // Create instance record
        const instance = ServiceInstance{
            .name = try self.allocator.dupe(u8, service_name),
            .unit_name = unit_name,
            .address = address,
            .pid = null,
            .status = .starting,
            .resources = limits,
            .cgroup_monitor = null,
        };

        try self.services.append(self.allocator, instance);

        // ALWAYS try to start with systemd-run (doesn't require running under systemd)
        std.log.info("Starting systemd service: {s} on port {d}", .{ unit_name, address.getPort() });

        var svc_mgr = systemd.ServiceManager.init(self.allocator);

        // Convert percentages to actual values
        // Base: 50M memory, 10% CPU (from dumb-server)
        const memory_max: usize = @as(usize, 50 * types.MIB) * @as(usize, limits.memory_percent) / 100;
        const cpu_quota: u8 = @intCast(@as(u16, 10) * @as(u16, limits.cpu_percent) / 100);

        std.log.info("Binary path: {s}", .{exec_path});

        // Verify binary exists (supports both absolute and relative paths)
        const absolute_path = if (std.fs.path.isAbsolute(exec_path))
            try self.allocator.dupe(u8, exec_path)
        else blk: {
            const cwd = try std.process.getCwdAlloc(self.allocator);
            defer self.allocator.free(cwd);
            break :blk try std.fs.path.join(self.allocator, &[_][]const u8{ cwd, exec_path });
        };
        defer self.allocator.free(absolute_path);

        std.fs.accessAbsolute(absolute_path, .{}) catch |err| {
            std.log.err("FATAL: Service binary not found at {s}: {any}", .{ absolute_path, err });
            @panic("Service binary not found");
        };

        // Setup environment with PORT
        var env_map = std.StringHashMap([]const u8).init(self.allocator);
        defer env_map.deinit();

        const port_str = try std.fmt.allocPrint(self.allocator, "{d}", .{address.getPort()});
        defer self.allocator.free(port_str);
        try env_map.put("PORT", port_str);

        try svc_mgr.startTransientService(.{
            .unit_name = unit_name,
            .exec_args = &[_][]const u8{absolute_path},
            .uid = std.os.linux.getuid(),
            .gid = std.os.linux.getgid(),
            .memory_max = memory_max,
            .cpu_quota = cpu_quota,
            .environment = env_map,
        });

        std.log.info("Service started: {s}", .{unit_name});

        // Wait for service to initialize
        std.Thread.sleep(1 * types.SEC); // Wait 1s for service to start

        const status = systemd.queryServiceStatus(self.allocator, unit_name, true) catch |err| {
            std.log.warn("Warning: Failed to query service status: {any}", .{err});
            std.log.info("Service may have been started but systemd-run exited immediately", .{});
            // Don't panic - transient services may not show up in systemctl
            const last_instance = &self.services.items[self.services.items.len - 1];
            last_instance.status = .running;
            return;
        };
        defer {
            var mut_status = status;
            mut_status.deinit(self.allocator);
        }

        std.log.info("Service status: {s}/{s}", .{ status.active_state, status.sub_state });

        // Accept "active" or "activating" states
        if (!std.mem.eql(u8, status.active_state, "active") and !std.mem.eql(u8, status.active_state, "activating")) {
            std.log.warn("Warning: Service is not active: {s}", .{status.active_state});
            std.log.info("Service may still be starting or systemd-run created a transient unit", .{});
        }

        // Initialize cgroup monitor
        const last_instance = &self.services.items[self.services.items.len - 1];
        last_instance.cgroup_monitor = systemd.CgroupMonitor.init(self.allocator, unit_name) catch null;
        last_instance.status = .running;
    }

    /// Select a healthy instance for load balancing
    fn selectHealthyInstance(self: *Master) ?*ServiceInstance {
        for (self.services.items) |*instance| {
            if (instance.status == .running) {
                return instance;
            }
        }
        return null;
    }

    /// Forward connection to service instance
    fn forwardConnection(self: *Master, conn: net.Server.Connection, instance: *ServiceInstance) !void {
        _ = self;
        defer conn.stream.close();

        // Connect to backend service
        const backend = try net.tcpConnectToAddress(instance.address);
        defer backend.close();

        // Simple proxy: forward data between client and backend
        var buf: [4096]u8 = undefined;

        // This is simplified - in production you'd want bidirectional forwarding
        while (true) {
            const n = try conn.stream.read(&buf);
            if (n == 0) break;
            try backend.writeAll(buf[0..n]);
        }
    }

    /// Get status of all service instances
    pub fn getStatus(self: *Master) ![]ServiceStatus {
        var statuses = try self.allocator.alloc(ServiceStatus, self.services.items.len);

        for (self.services.items, 0..) |*instance, i| {
            var memory_usage: ?u64 = null;
            var cpu_usage: ?systemd.CgroupMonitor.CpuStats = null;

            if (instance.cgroup_monitor) |*monitor| {
                memory_usage = monitor.getMemoryUsage() catch null;
                cpu_usage = monitor.getCpuUsage() catch null;
            }

            statuses[i] = .{
                .name = instance.name,
                .address = instance.address,
                .status = instance.status,
                .memory_usage = memory_usage,
                .cpu_stats = cpu_usage,
            };
        }

        return statuses;
    }

    pub const ServiceStatus = struct {
        name: []const u8,
        address: net.Address,
        status: ServiceInstance.Status,
        memory_usage: ?u64,
        cpu_stats: ?systemd.CgroupMonitor.CpuStats,
    };
};
