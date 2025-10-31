const std = @import("std");
const net = std.net;
const assert = std.debug.assert;
const systemd = @import("systemd.zig");
const cli = @import("cli.zig");
const types = @import("types.zig");
const constants = @import("constants.zig");
const config_mod = @import("config.zig");
const iops = @import("iops.zig");

/// Master orchestrator that manages service instances
/// Uses static memory allocation - all resources bounded at compile time
pub const Master = struct {
    allocator: std.mem.Allocator,
    limits: constants.RuntimeLimits,
    bind_address: net.Address,

    // Static pools - sized from RuntimeLimits at init
    services: types.BoundedArray(ServiceInstance, constants.max_service_instances),
    proxy_connections: iops.IOPSType(types.ProxyConnection, 64),  // Max 64 for BitSet
    proxy_buffers: iops.IOPSType([4096]u8, 64), // Match proxy_connections size

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

    pub fn init(allocator: std.mem.Allocator, limits: constants.RuntimeLimits, bind_address: net.Address) !Master {
        assert(@intFromPtr(&allocator) != 0); // Allocator must be valid
        // Validate limits before proceeding
        try limits.validate();

        var notifier: ?systemd.Notifier = null;
        var watchdog: ?systemd.Watchdog = null;

        // Initialize systemd integration if available
        if (systemd.isUnderSystemd()) {
            notifier = systemd.Notifier.init(allocator);
            if (notifier) |*n| {
                watchdog = try systemd.Watchdog.init(n, allocator);
            }
        }

        // Log memory allocation plan
        limits.format_memory_usage();

        return Master{
            .allocator = allocator,
            .limits = limits,
            .bind_address = bind_address,
            .services = types.BoundedArray(ServiceInstance, constants.max_service_instances).init(),
            .proxy_connections = .{},
            .proxy_buffers = .{},
            .systemd_notifier = notifier,
            .watchdog = watchdog,
        };
    }

    pub fn deinit(self: *Master) void {
        assert(@intFromPtr(self) != 0); // Self must be valid

        if (self.systemd_notifier) |*notifier| {
            notifier.deinit();
        }

        // Clean up cgroup monitors
        for (self.services.slice_mut()) |*service| {
            if (service.cgroup_monitor) |*monitor| {
                monitor.deinit();
            }
        }

        // Note: services BoundedArray doesn't need explicit deinit
        // Memory is statically allocated
    }

    /// Start the master orchestrator
    pub fn start(self: *Master, config: config_mod.Config) !void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(config.services.len > 0); // Must have at least one service

        // Notify systemd we're starting
        if (self.systemd_notifier) |*notifier| {
            try notifier.status("Starting L1NE orchestrator...");
        }

        // Deploy service instances from config
        for (config.services) |service_config| {
            const addr = try net.Address.parseIp4("127.0.0.1", service_config.port);
            try self.deployInstance(
                service_config.name,
                service_config.exec_path,
                addr,
                .{
                    .memory_percent = @intCast(service_config.memory_mb),
                    .cpu_percent = service_config.cpu_percent,
                },
            );
        }

        assert(self.services.len > 0); // Must have deployed at least one service

        // Start load balancer
        var server = try net.Address.listen(self.bind_address, .{
            .reuse_address = true,
        });
        defer server.deinit();

        // Notify systemd we're ready
        if (self.systemd_notifier) |*notifier| {
            try notifier.ready();
            const status_msg = try std.fmt.allocPrint(
                self.allocator,
                "Managing {d} service instances",
                .{self.services.len},
            );
            defer self.allocator.free(status_msg);
            try notifier.status(status_msg);
        }

        std.log.info("L1NE orchestrator listening on {any}", .{self.bind_address});
        std.log.info("Managing {any} service instances", .{self.services.len});
        std.log.info("Proxy pool: {any} connections max", .{self.proxy_connections.items.len});

        // Main loop - runs forever with bounded memory
        while (true) {
            assert(!self.services.is_empty()); // Must have services

            // Send watchdog keepalive if needed
            if (self.watchdog) |*wd| {
                try wd.keepaliveIfNeeded();
            }

            // Accept connections and load balance
            if (server.accept()) |conn| {
                // Round-robin load balancing
                const instance = self.selectHealthyInstance() orelse {
                    std.log.warn("No healthy instances, dropping connection", .{});
                    conn.stream.close();
                    continue;
                };

                // Forward to selected instance (with backpressure)
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
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: service_name is non-empty
    ///   - Pre: exec_path is non-empty
    ///   - Pre: address has valid port
    ///   - Pre: services array has space available
    ///   - Post: service is added to services array
    ///   - Post: service is started via systemd
    ///   - Post: cgroup monitor is initialized
    ///
    /// This is the orchestration function - delegates to smaller helpers
    fn deployInstance(
        self: *Master,
        service_name: []const u8,
        exec_path: []const u8,
        address: net.Address,
        limits: ServiceInstance.ResourceLimits,
    ) !void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(service_name.len > 0); // Name must not be empty
        assert(service_name.len < 256); // Name must be reasonable length
        assert(exec_path.len > 0); // Path must not be empty
        assert(exec_path.len < std.fs.max_path_bytes); // Path must be valid length
        assert(address.getPort() > 0); // Port must be non-zero
        assert(address.getPort() < 65536); // Port must be valid

        std.log.info("Deploying {s} instance at port {d}", .{ service_name, address.getPort() });

        // Step 1: Create instance record and add to array
        const unit_name = try self.createServiceInstance(service_name, address, limits);

        // Step 2: Resolve and verify binary path
        const absolute_path = try self.resolveBinaryPath(exec_path);
        defer self.allocator.free(absolute_path);

        // Step 3: Start service via systemd
        try self.startSystemdService(unit_name, absolute_path, address, limits);

        // Step 4: Wait for service to become ready
        try self.waitForServiceReady(unit_name);

        // Step 5: Initialize cgroup monitoring
        try self.initializeCgroupMonitor(unit_name);

        std.log.info("Deployment complete: {s}", .{service_name});
    }

    /// Create service instance record and add to services array
    ///
    /// Invariants:
    ///   - Pre: self is valid, service_name non-empty, address valid
    ///   - Pre: services array has capacity
    ///   - Post: instance added to services array with .starting status
    ///   - Returns: allocated unit name (caller must free)
    fn createServiceInstance(
        self: *Master,
        service_name: []const u8,
        address: net.Address,
        limits: ServiceInstance.ResourceLimits,
    ) ![]const u8 {
        assert(@intFromPtr(self) != 0);
        assert(service_name.len > 0);
        assert(address.getPort() > 0);

        const old_len = self.services.len;
        assert(old_len < self.services.capacity_total()); // Must have space

        // Generate systemd unit name
        const unit_name = try std.fmt.allocPrint(
            self.allocator,
            "l1ne-{s}-{d}.service",
            .{ service_name, address.getPort() },
        );
        errdefer self.allocator.free(unit_name);

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

        // Add to static services array (with bounds checking)
        try self.services.push(instance);

        assert(self.services.len == old_len + 1); // Verify added
        assert(self.services.items[old_len].status == .starting); // Verify status

        return unit_name;
    }

    /// Resolve binary path to absolute path and verify it exists
    ///
    /// Invariants:
    ///   - Pre: self is valid, exec_path non-empty
    ///   - Post: returned path is absolute
    ///   - Post: binary exists and is accessible
    ///   - Returns: allocated absolute path (caller must free)
    fn resolveBinaryPath(self: *Master, exec_path: []const u8) ![]const u8 {
        assert(@intFromPtr(self) != 0);
        assert(exec_path.len > 0);
        assert(exec_path.len < std.fs.max_path_bytes);

        std.log.info("Resolving binary path: {s}", .{exec_path});

        // Convert to absolute path if needed
        const absolute_path = if (std.fs.path.isAbsolute(exec_path))
            try self.allocator.dupe(u8, exec_path)
        else blk: {
            const cwd = try std.process.getCwdAlloc(self.allocator);
            defer self.allocator.free(cwd);
            break :blk try std.fs.path.join(self.allocator, &[_][]const u8{ cwd, exec_path });
        };
        errdefer self.allocator.free(absolute_path);

        assert(std.fs.path.isAbsolute(absolute_path)); // Must be absolute now
        assert(absolute_path.len < std.fs.max_path_bytes); // Must be valid length

        // Verify binary exists and is accessible
        std.fs.accessAbsolute(absolute_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.err("Service binary not found: {s}", .{absolute_path});
                return error.BinaryNotFound;
            },
            error.AccessDenied => {
                std.log.err("Service binary not accessible (permissions): {s}", .{absolute_path});
                return error.BinaryNotAccessible;
            },
            else => {
                std.log.err("Failed to access binary {s}: {any}", .{ absolute_path, err });
                return err;
            },
        };

        std.log.info("Binary verified: {s}", .{absolute_path});
        return absolute_path;
    }

    /// Start service via systemd with resource limits
    ///
    /// Invariants:
    ///   - Pre: all parameters valid and non-empty
    ///   - Pre: absolute_path exists and is accessible
    ///   - Post: systemd service is started (transient unit)
    fn startSystemdService(
        self: *Master,
        unit_name: []const u8,
        absolute_path: []const u8,
        address: net.Address,
        limits: ServiceInstance.ResourceLimits,
    ) !void {
        assert(@intFromPtr(self) != 0);
        assert(unit_name.len > 0);
        assert(absolute_path.len > 0);
        assert(std.fs.path.isAbsolute(absolute_path));
        assert(address.getPort() > 0);

        std.log.info("Starting systemd service: {s} on port {d}", .{ unit_name, address.getPort() });

        var svc_mgr = systemd.ServiceManager.init(self.allocator);

        // Convert percentages to actual values
        // Base: 50M memory, 10% CPU (from dumb-server)
        const memory_max: u64 = @as(u64, 50 * types.MIB) * @as(u64, limits.memory_percent) / 100;
        const cpu_quota: u8 = @intCast(@as(u16, 10) * @as(u16, limits.cpu_percent) / 100);

        assert(memory_max > 0); // Must have non-zero memory
        assert(cpu_quota > 0); // Must have non-zero CPU

        // Setup environment with PORT
        var env_map = std.StringHashMap([]const u8).init(self.allocator);
        defer env_map.deinit();

        const port_str = try std.fmt.allocPrint(self.allocator, "{d}", .{address.getPort()});
        defer self.allocator.free(port_str);
        try env_map.put("PORT", port_str);

        // Start transient service
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
    }

    /// Wait for service to become ready and verify status
    ///
    /// Invariants:
    ///   - Pre: self valid, unit_name non-empty
    ///   - Pre: service was just started
    ///   - Post: service status is .running (or warning logged if unavailable)
    fn waitForServiceReady(self: *Master, unit_name: []const u8) !void {
        assert(@intFromPtr(self) != 0);
        assert(unit_name.len > 0);
        assert(self.services.len > 0); // Must have at least one service

        // Wait for service to initialize (give it time to start)
        std.Thread.sleep(1 * types.SEC);

        const status = systemd.queryServiceStatus(self.allocator, unit_name, true) catch |err| {
            // Transient services may not show up in systemctl immediately
            std.log.warn("Failed to query service status: {any}", .{err});
            std.log.info("Service may have started but systemd-run exited", .{});

            // Mark as running anyway (optimistic)
            const last_instance = &self.services.items[self.services.len - 1];
            assert(last_instance.status == .starting); // Must still be starting
            last_instance.status = .running;
            return;
        };
        defer {
            var mut_status = status;
            mut_status.deinit(self.allocator);
        }

        std.log.info("Service status: {s}/{s}", .{ status.active_state, status.sub_state });

        // Accept "active" or "activating" states
        const is_active = std.mem.eql(u8, status.active_state, "active");
        const is_activating = std.mem.eql(u8, status.active_state, "activating");

        if (!is_active and !is_activating) {
            std.log.warn("Service is not active: {s}", .{status.active_state});
            std.log.info("Service may still be starting", .{});
        }

        // Mark as running
        const last_instance = &self.services.items[self.services.len - 1];
        assert(last_instance.status == .starting); // Must still be starting
        last_instance.status = .running;
    }

    /// Initialize cgroup monitor for resource tracking
    ///
    /// Invariants:
    ///   - Pre: self valid, unit_name non-empty
    ///   - Pre: services array not empty
    ///   - Post: last service has cgroup_monitor set (may be null if init fails)
    fn initializeCgroupMonitor(self: *Master, unit_name: []const u8) !void {
        assert(@intFromPtr(self) != 0);
        assert(unit_name.len > 0);
        assert(self.services.len > 0); // Must have at least one service

        const last_instance = &self.services.items[self.services.len - 1];
        assert(last_instance.status == .running); // Must be running now

        // Try to initialize cgroup monitor (may fail if cgroup not available)
        last_instance.cgroup_monitor = systemd.CgroupMonitor.init(
            self.allocator,
            unit_name,
        ) catch |err| blk: {
            std.log.warn("Failed to initialize cgroup monitor: {any}", .{err});
            std.log.info("Resource monitoring will be unavailable", .{});
            break :blk null;
        };

        if (last_instance.cgroup_monitor != null) {
            std.log.info("Cgroup monitor initialized: {s}", .{unit_name});
        }
    }

    /// Select a healthy instance for load balancing
    fn selectHealthyInstance(self: *Master) ?*ServiceInstance {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(self.services.len > 0); // Must have services

        for (self.services.slice_mut()) |*instance| {
            assert(@intFromPtr(instance) != 0); // Instance must be valid
            if (instance.status == .running) {
                return instance;
            }
        }
        return null;
    }

    /// Forward connection to service instance using static buffer pool
    /// Implements natural backpressure - returns error if proxy pool exhausted
    ///
    /// Invariants:
    ///   - Pre: self and instance are valid pointers
    ///   - Pre: conn.stream is open and valid
    ///   - Pre: instance.address is reachable
    ///   - Post: connection is closed (via defer)
    ///   - Post: buffers are released (via defer)
    ///
    /// This function orchestrates bidirectional proxying between client and backend
    fn forwardConnection(self: *Master, conn: net.Server.Connection, instance: *ServiceInstance) !void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(@intFromPtr(instance) != 0); // Instance must be valid
        assert(conn.stream.handle >= 0); // Stream must be open
        defer conn.stream.close();

        // Acquire TWO buffers (one for each direction)
        const buffer_c2b = self.proxy_buffers.acquire() orelse {
            std.log.warn("Proxy buffer pool exhausted ({d}/{d}), dropping connection", .{
                self.proxy_buffers.busy_count(),
                self.proxy_buffers.items.len,
            });
            return error.ResourceExhausted;
        };
        defer self.proxy_buffers.release(buffer_c2b);

        const buffer_b2c = self.proxy_buffers.acquire() orelse {
            std.log.warn("Proxy buffer pool exhausted for return path ({d}/{d})", .{
                self.proxy_buffers.busy_count(),
                self.proxy_buffers.items.len,
            });
            return error.ResourceExhausted;
        };
        defer self.proxy_buffers.release(buffer_b2c);

        assert(@intFromPtr(buffer_c2b) != 0); // Buffer must be valid
        assert(@intFromPtr(buffer_b2c) != 0); // Buffer must be valid
        assert(@intFromPtr(buffer_c2b) != @intFromPtr(buffer_b2c)); // Must be different buffers

        // Connect to backend service
        const backend = try self.connectToBackend(instance.address);
        defer backend.close();

        // Perform bidirectional proxy
        try self.proxyBidirectional(conn.stream, backend, buffer_c2b, buffer_b2c);

        assert(self.proxy_buffers.busy_count() <= self.proxy_buffers.items.len); // Sanity check
    }

    /// Connect to backend service with proper error handling
    ///
    /// Invariants:
    ///   - Pre: address is valid with non-zero port
    ///   - Post: returned stream is open and ready
    ///   - Returns specific errors for different failure modes
    fn connectToBackend(self: *Master, address: net.Address) !net.Stream {
        assert(@intFromPtr(self) != 0);
        assert(address.getPort() > 0);
        assert(address.getPort() < 65536);

        const stream = net.tcpConnectToAddress(address) catch |err| switch (err) {
            error.ConnectionRefused => {
                std.log.err("Backend refused connection: {any}", .{address});
                return error.BackendRefused;
            },
            error.NetworkUnreachable => {
                std.log.err("Backend unreachable: {any}", .{address});
                return error.BackendUnreachable;
            },
            error.ConnectionTimedOut => {
                std.log.err("Backend connection timeout: {any}", .{address});
                return error.BackendTimeout;
            },
            else => {
                std.log.err("Failed to connect to backend {any}: {any}", .{ address, err });
                return err;
            },
        };

        assert(stream.handle >= 0); // Stream must be open
        return stream;
    }

    /// Context for thread-based proxy direction
    const ProxyThreadContext = struct {
        master: *Master,
        src: net.Stream,
        dst: net.Stream,
        buffer: []u8,
        direction: []const u8,
        result: ?anyerror = null,
    };

    /// Thread entry point for proxying one direction
    ///
    /// Invariants:
    ///   - Pre: ctx_opaque is valid ProxyThreadContext pointer
    ///   - Post: ctx.result contains error or null on success
    fn proxyThreadEntry(ctx_opaque: *anyopaque) void {
        const ctx: *ProxyThreadContext = @ptrCast(@alignCast(ctx_opaque));
        assert(@intFromPtr(ctx) != 0); // Context must be valid
        assert(@intFromPtr(ctx.master) != 0); // Master must be valid
        assert(ctx.src.handle >= 0); // Source stream must be open
        assert(ctx.dst.handle >= 0); // Destination stream must be open

        // Run proxy direction and store any error in context
        ctx.master.proxyDirection(ctx.src, ctx.dst, ctx.buffer, ctx.direction) catch |err| {
            ctx.result = err;
            return;
        };

        ctx.result = null; // Success
    }

    /// Proxy data bidirectionally between client and backend
    ///
    /// Invariants:
    ///   - Pre: both streams are open and valid
    ///   - Pre: buffers are non-overlapping and valid
    ///   - Pre: buffer lengths match proxy_buffer_size
    ///   - Post: both directions reached EOF or error
    ///
    /// Uses thread-based concurrent forwarding for true bidirectional proxy
    /// One thread handles backend→client, main thread handles client→backend
    fn proxyBidirectional(
        self: *Master,
        client: net.Stream,
        backend: net.Stream,
        buffer_c2b: []u8,
        buffer_b2c: []u8,
    ) !void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(client.handle >= 0); // Client stream must be open
        assert(backend.handle >= 0); // Backend stream must be open
        assert(buffer_c2b.len > 0); // Client→backend buffer must be valid
        assert(buffer_b2c.len > 0); // Backend→client buffer must be valid
        assert(@intFromPtr(buffer_c2b.ptr) != @intFromPtr(buffer_b2c.ptr)); // Different buffers

        // Context for backend→client thread
        var b2c_context = ProxyThreadContext{
            .master = self,
            .src = backend,
            .dst = client,
            .buffer = buffer_b2c,
            .direction = "backend→client",
        };

        // Spawn thread for backend→client direction
        const thread = std.Thread.spawn(.{}, proxyThreadEntry, .{&b2c_context}) catch |err| {
            std.log.err("Failed to spawn proxy thread: {any}", .{err});
            return err;
        };

        // Main thread handles client→backend direction
        const c2b_result = self.proxyDirection(client, backend, buffer_c2b, "client→backend");

        // Wait for backend→client thread to complete
        thread.join();

        // Check results from both directions
        if (c2b_result) |_| {
            // Client→backend succeeded, check backend→client
            if (b2c_context.result) |b2c_err| {
                std.log.warn("Backend→client error: {any}", .{b2c_err});
                return b2c_err;
            }
        } else |c2b_err| {
            std.log.warn("Client→backend error: {any}", .{c2b_err});
            // Check if backend→client also had error
            if (b2c_context.result) |b2c_err| {
                std.log.warn("Backend→client also error: {any}", .{b2c_err});
            }
            return c2b_err;
        }

        std.log.info("Bidirectional proxy completed successfully", .{});
    }

    /// Proxy data in one direction until EOF or error
    ///
    /// Invariants:
    ///   - Pre: src and dst streams are open
    ///   - Pre: buffer is valid and non-empty
    ///   - Post: forwarded all data until EOF or error
    fn proxyDirection(
        self: *Master,
        src: net.Stream,
        dst: net.Stream,
        buffer: []u8,
        direction: []const u8,
    ) !void {
        assert(@intFromPtr(self) != 0);
        assert(src.handle >= 0);
        assert(dst.handle >= 0);
        assert(buffer.len > 0);
        assert(direction.len > 0);

        var bytes_forwarded: u64 = 0;

        while (true) {
            const n = src.read(buffer) catch |err| switch (err) {
                error.WouldBlock => continue, // Non-blocking mode, retry
                error.ConnectionResetByPeer => {
                    std.log.info("{s}: connection reset ({d} bytes forwarded)", .{ direction, bytes_forwarded });
                    break;
                },
                error.BrokenPipe => {
                    std.log.info("{s}: broken pipe ({d} bytes forwarded)", .{ direction, bytes_forwarded });
                    break;
                },
                else => {
                    std.log.err("{s}: read error after {d} bytes: {any}", .{ direction, bytes_forwarded, err });
                    return err;
                },
            };

            if (n == 0) {
                // EOF reached
                std.log.info("{s}: EOF after {d} bytes", .{ direction, bytes_forwarded });
                break;
            }

            assert(n <= buffer.len); // Read cannot exceed buffer size

            // Forward to destination
            dst.writeAll(buffer[0..n]) catch |err| switch (err) {
                error.BrokenPipe => {
                    std.log.info("{s}: destination closed ({d} bytes forwarded)", .{ direction, bytes_forwarded });
                    break;
                },
                error.ConnectionResetByPeer => {
                    std.log.info("{s}: destination reset ({d} bytes forwarded)", .{ direction, bytes_forwarded });
                    break;
                },
                else => {
                    std.log.err("{s}: write error after {d} bytes: {any}", .{ direction, bytes_forwarded, err });
                    return err;
                },
            };

            bytes_forwarded += n;
        }

        std.log.info("{s}: completed ({d} bytes total)", .{ direction, bytes_forwarded });
    }

    /// Get status of all service instances
    pub fn getStatus(self: *Master) ![]ServiceStatus {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(self.services.len > 0); // Must have services

        var statuses = try self.allocator.alloc(ServiceStatus, self.services.len);

        for (self.services.slice(), 0..) |*instance, i| {
            assert(@intFromPtr(instance) != 0); // Instance must be valid
            assert(i < self.services.len); // Index must be in bounds

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

        assert(statuses.len == self.services.len); // Result must match services count
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
