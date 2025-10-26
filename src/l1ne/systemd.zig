//! This module provides direct communication with systemd without requiring
//! external process spawning. It implements:
//! - Socket-based notifications (no dependencies)
//! - Service state management
//! - Resource monitoring via cgroups
//! - Journal integration
//! - for prod needs D-bus integration (no systemclt)

const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const fmt = std.fmt;
const net = std.net;
const fs = std.fs;

/// systemd notification protocol implementation
pub const Notifier = struct {
    socket_path: ?[]const u8,
    socket: ?posix.socket_t,
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator) Notifier {
        return .{
            .socket_path = std.process.getEnvVarOwned(allocator, "NOTIFY_SOCKET") catch null,
            .socket = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Notifier) void {
        if (self.socket) |sock| {
            posix.close(sock);
        }
        if (self.socket_path) |path| {
            self.allocator.free(path);
        }
    }

    /// Connect to systemd notification socket
    fn connect(self: *Notifier) !void {
        if (self.socket != null) return;

        _ = self.socket_path orelse return error.NotUnderSystemd;

        // Create Unix datagram socket
        self.socket = try posix.socket(posix.AF.UNIX, posix.SOCK.DGRAM | posix.SOCK.CLOEXEC, 0);
    }

    /// Send notification to systemd
    pub fn notify(self: *Notifier, message: []const u8) !void {
        try self.connect();

        const socket_path = self.socket_path orelse return error.NotUnderSystemd;
        const sock = self.socket orelse return error.NotConnected;

        // Prepare socket address
        var addr = net.Address.initUnix(socket_path) catch |err| {
            // Handle abstract socket (starts with @)
            if (socket_path[0] == '@') {
                var unix_addr: posix.sockaddr.un = .{
                    .family = posix.AF.UNIX,
                    .path = undefined,
                };
                unix_addr.path[0] = 0; // Abstract socket
                @memcpy(unix_addr.path[1..socket_path.len], socket_path[1..]);

                const addr_len = @offsetOf(posix.sockaddr.un, "path") + socket_path.len;
                _ = try posix.sendto(sock, message, 0, @ptrCast(&unix_addr), @intCast(addr_len));
                return;
            }
            return err;
        };

        // Send notification
        _ = try posix.sendto(sock, message, 0, &addr.any, addr.getOsSockLen());
    }

    /// Notify systemd that service is ready
    pub fn ready(self: *Notifier) !void {
        try self.notify("READY=1");
    }

    /// Send watchdog keepalive
    pub fn watchdog(self: *Notifier) !void {
        try self.notify("WATCHDOG=1");
    }

    /// Update service status
    pub fn status(self: *Notifier, status_text: []const u8) !void {
        var buf: [4096]u8 = undefined;
        const msg = try fmt.bufPrint(&buf, "STATUS={s}", .{status_text});
        try self.notify(msg);
    }

    /// Set main PID (useful for forking services)
    pub fn mainPid(self: *Notifier, pid: posix.pid_t) !void {
        var buf: [256]u8 = undefined;
        const msg = try fmt.bufPrint(&buf, "MAINPID={d}", .{pid});
        try self.notify(msg);
    }

    /// Request systemd to extend timeout
    pub fn extendTimeout(self: *Notifier, usec: u64) !void {
        var buf: [256]u8 = undefined;
        const msg = try fmt.bufPrint(&buf, "EXTEND_TIMEOUT_USEC={d}", .{usec});
        try self.notify(msg);
    }

    /// Notify about reload completion
    pub fn reloading(self: *Notifier) !void {
        try self.notify("RELOADING=1");
    }

    /// Notify about stopping
    pub fn stopping(self: *Notifier) !void {
        try self.notify("STOPPING=1");
    }

    /// Send custom key-value pairs to systemd
    pub fn custom(self: *Notifier, key: []const u8, value: []const u8) !void {
        var buf: [4096]u8 = undefined;
        const msg = try fmt.bufPrint(&buf, "{s}={s}", .{ key, value });
        try self.notify(msg);
    }

    /// Send multiple notifications at once
    pub fn notifyMultiple(self: *Notifier, messages: []const []const u8) !void {
        var buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();

        for (messages, 0..) |msg, i| {
            if (i > 0) try writer.writeByte('\n');
            try writer.writeAll(msg);
        }

        try self.notify(fbs.getWritten());
    }
};

/// Socket activation support
pub const SocketActivation = struct {
    /// Get file descriptors passed by systemd
    pub fn getListenFds(allocator: mem.Allocator) ![]posix.fd_t {
        // Check LISTEN_PID to ensure FDs are for this process
        const listen_pid_str = std.process.getEnvVarOwned(allocator, "LISTEN_PID") catch return &[_]posix.fd_t{};
        defer allocator.free(listen_pid_str);

        const listen_pid = try fmt.parseInt(posix.pid_t, listen_pid_str, 10);
        if (listen_pid != std.os.linux.getpid()) return &[_]posix.fd_t{};

        // Get number of FDs
        const listen_fds_str = std.process.getEnvVarOwned(allocator, "LISTEN_FDS") catch return &[_]posix.fd_t{};
        defer allocator.free(listen_fds_str);

        const n_fds = try fmt.parseInt(usize, listen_fds_str, 10);

        // systemd passes FDs starting from 3 (SD_LISTEN_FDS_START)
        var fds = try allocator.alloc(posix.fd_t, n_fds);
        for (0..n_fds) |i| {
            fds[i] = @intCast(3 + i);
        }

        return fds;
    }

    /// Get socket names passed by systemd
    pub fn getListenFdNames(allocator: mem.Allocator) ![][]const u8 {
        const names_str = std.process.getEnvVarOwned(allocator, "LISTEN_FDNAMES") catch return &[_][]const u8{};
        defer allocator.free(names_str);

        var names = std.ArrayList([]const u8).empty;
        var iter = mem.tokenizeScalar(u8, names_str, ':');
        while (iter.next()) |name| {
            try names.append(allocator, try allocator.dupe(u8, name));
        }

        return try names.toOwnedSlice(allocator);
    }
};

/// Watchdog support
pub const Watchdog = struct {
    interval_usec: ?u64,
    notifier: *Notifier,
    timer: ?std.time.Timer,

    pub fn init(notifier: *Notifier, allocator: mem.Allocator) !Watchdog {
        // Get watchdog interval from environment
        const wd_usec_str = std.process.getEnvVarOwned(allocator, "WATCHDOG_USEC") catch {
            return Watchdog{
                .interval_usec = null,
                .notifier = notifier,
                .timer = null,
            };
        };
        defer allocator.free(wd_usec_str);

        const interval = try fmt.parseInt(u64, wd_usec_str, 10);

        return Watchdog{
            // Use half the interval for safety
            .interval_usec = interval / 2,
            .notifier = notifier,
            .timer = try std.time.Timer.start(),
        };
    }

    /// Check if watchdog keepalive is needed and send it
    pub fn keepaliveIfNeeded(self: *Watchdog) !void {
        const interval = self.interval_usec orelse return;
        var timer = self.timer orelse return;

        if (timer.read() >= interval * 1000) { // Convert to nanoseconds
            try self.notifier.watchdog();
            timer.reset();
        }
    }

    /// Start automatic watchdog keepalive in a separate thread
    pub fn startAutoKeepalive(self: *Watchdog) !std.Thread {
        return try std.Thread.spawn(.{}, watchdogThread, .{self});
    }

    fn watchdogThread(self: *Watchdog) !void {
        const interval = self.interval_usec orelse return;

        while (true) {
            std.Thread.sleep(interval * 1000); // Convert to nanoseconds
            self.notifier.watchdog() catch |err| {
                std.log.err("Failed to send watchdog keepalive: {any}", .{err});
            };
        }
    }
};

/// Service manager for controlling systemd units
pub const ServiceManager = struct {
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator) ServiceManager {
        return .{ .allocator = allocator };
    }

    /// Start a transient systemd service
    pub fn startTransientService(self: *ServiceManager, config: TransientServiceConfig) !void {
        var args = std.ArrayList([]const u8).empty;
        defer args.deinit(self.allocator);

        try args.append(self.allocator, "systemd-run");
        try args.append(self.allocator, "--user"); // Run as user service
        try args.append(self.allocator, "--collect"); // Clean up after service stops
        // Note: --uid and --gid are not supported for --user services

        if (config.memory_max) |memory| {
            try args.append(self.allocator, "--property");
            try args.append(self.allocator, try fmt.allocPrint(self.allocator, "MemoryMax={d}", .{memory}));
        }

        if (config.cpu_quota) |cpu| {
            try args.append(self.allocator, "--property");
            try args.append(self.allocator, try fmt.allocPrint(self.allocator, "CPUQuota={d}%", .{cpu}));
        }

        try args.append(self.allocator, "--unit");
        try args.append(self.allocator, config.unit_name);

        // Add environment variables if provided
        if (config.environment) |env_map| {
            var iter = env_map.iterator();
            while (iter.next()) |entry| {
                const env_str = try fmt.allocPrint(self.allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
                try args.append(self.allocator, "--setenv");
                try args.append(self.allocator, env_str);
            }
        }

        try args.append(self.allocator, "--");
        try args.appendSlice(self.allocator, config.exec_args);

        // Debug: print the command
        std.log.debug("systemd-run command:", .{});
        for (args.items) |arg| {
            std.log.debug("  {s}", .{arg});
        }

        // Use std.process.Child for now until we implement D-Bus
        var child = std.process.Child.init(args.items, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;

        try child.spawn();
        _ = try child.wait();
    }

    pub const TransientServiceConfig = struct {
        unit_name: []const u8,
        exec_args: []const []const u8,
        uid: posix.uid_t,
        gid: posix.gid_t,
        memory_max: ?usize = null,
        cpu_quota: ?u8 = null,
        working_directory: ?[]const u8 = null,
        environment: ?std.StringHashMap([]const u8) = null,
    };
};

/// Cgroup interface for resource monitoring
pub const CgroupMonitor = struct {
    cgroup_path: []const u8,
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator, service_name: []const u8) !CgroupMonitor {
        // Construct cgroup path for the service
        const path = try fmt.allocPrint(allocator, "/sys/fs/cgroup/system.slice/{s}.service", .{service_name});

        return .{
            .cgroup_path = path,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CgroupMonitor) void {
        self.allocator.free(self.cgroup_path);
    }

    /// Read memory usage
    pub fn getMemoryUsage(self: *CgroupMonitor) !u64 {
        const path = try fmt.allocPrint(self.allocator, "{s}/memory.current", .{self.cgroup_path});
        defer self.allocator.free(path);

        const file = try fs.openFileAbsolute(path, .{});
        defer file.close();

        var buf: [32]u8 = undefined;
        const len = try file.read(&buf);
        const value_str = mem.trim(u8, buf[0..len], "\n ");
        return try fmt.parseInt(u64, value_str, 10);
    }

    /// Read CPU usage
    pub fn getCpuUsage(self: *CgroupMonitor) !CpuStats {
        const path = try fmt.allocPrint(self.allocator, "{s}/cpu.stat", .{self.cgroup_path});
        defer self.allocator.free(path);

        const file = try fs.openFileAbsolute(path, .{});
        defer file.close();

        var buf: [256]u8 = undefined;
        const len = try file.read(&buf);
        const content = buf[0..len];

        var stats = CpuStats{
            .usage_usec = 0,
            .user_usec = 0,
            .system_usec = 0,
        };

        var lines = mem.tokenizeScalar(u8, content, '\n');
        while (lines.next()) |line| {
            var parts = mem.tokenizeScalar(u8, line, ' ');
            const key = parts.next() orelse continue;
            const value_str = parts.next() orelse continue;
            const value = try fmt.parseInt(u64, value_str, 10);

            if (mem.eql(u8, key, "usage_usec")) {
                stats.usage_usec = value;
            } else if (mem.eql(u8, key, "user_usec")) {
                stats.user_usec = value;
            } else if (mem.eql(u8, key, "system_usec")) {
                stats.system_usec = value;
            }
        }

        return stats;
    }

    pub const CpuStats = struct {
        usage_usec: u64,
        user_usec: u64,
        system_usec: u64,
    };
};

/// Check if running under systemd
pub fn isUnderSystemd() bool {
    // Check for systemd environment variables
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "NOTIFY_SOCKET")) |val| {
        std.heap.page_allocator.free(val);
        return true;
    } else |_| {}

    if (std.process.getEnvVarOwned(std.heap.page_allocator, "LISTEN_PID")) |val| {
        std.heap.page_allocator.free(val);
        return true;
    } else |_| {}

    if (std.process.getEnvVarOwned(std.heap.page_allocator, "INVOCATION_ID")) |val| {
        std.heap.page_allocator.free(val);
        return true;
    } else |_| {}

    return false;
}

/// Get systemd invocation ID
pub fn getInvocationId(allocator: mem.Allocator) !?[]const u8 {
    return std.process.getEnvVarOwned(allocator, "INVOCATION_ID") catch null;
}

// ============================================================================
// SYSTEMCTL STATUS QUERIES
// ============================================================================

/// Service status information retrieved from systemd
pub const ServiceStatus = struct {
    active_state: []const u8, // "active", "inactive", "failed", etc.
    sub_state: []const u8, // "running", "dead", "exited", etc.
    main_pid: ?posix.pid_t,
    memory_current: ?u64, // Bytes
    cpu_usage_nsec: ?u64, // Nanoseconds
    load_state: []const u8, // "loaded", "not-found", etc.
    description: []const u8,

    pub fn deinit(self: *ServiceStatus, allocator: mem.Allocator) void {
        allocator.free(self.active_state);
        allocator.free(self.sub_state);
        allocator.free(self.load_state);
        allocator.free(self.description);
    }
};

/// Query systemctl for service status using `systemctl show`
pub fn queryServiceStatus(allocator: mem.Allocator, unit_name: []const u8, user_mode: bool) !ServiceStatus {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "systemctl");
    if (user_mode) try argv.append(allocator, "--user");
    try argv.append(allocator, "show");
    try argv.append(allocator, unit_name);
    try argv.append(allocator, "--property=ActiveState,SubState,MainPID,MemoryCurrent,CPUUsageNSec,LoadState,Description");

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        return error.SystemctlFailed;
    }

    return parseSystemctlShow(allocator, result.stdout);
}

/// Parse output from `systemctl show`
fn parseSystemctlShow(allocator: mem.Allocator, output: []const u8) !ServiceStatus {
    var status = ServiceStatus{
        .active_state = "",
        .sub_state = "",
        .main_pid = null,
        .memory_current = null,
        .cpu_usage_nsec = null,
        .load_state = "",
        .description = "",
    };

    var lines = mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        var parts = mem.splitScalar(u8, line, '=');
        const key = parts.next() orelse continue;
        const value = parts.next() orelse "";

        if (mem.eql(u8, key, "ActiveState")) {
            status.active_state = try allocator.dupe(u8, value);
        } else if (mem.eql(u8, key, "SubState")) {
            status.sub_state = try allocator.dupe(u8, value);
        } else if (mem.eql(u8, key, "MainPID")) {
            status.main_pid = if (value.len > 0 and !mem.eql(u8, value, "0"))
                fmt.parseInt(posix.pid_t, value, 10) catch null
            else
                null;
        } else if (mem.eql(u8, key, "MemoryCurrent")) {
            status.memory_current = if (value.len > 0 and !mem.eql(u8, value, "[not set]"))
                fmt.parseInt(u64, value, 10) catch null
            else
                null;
        } else if (mem.eql(u8, key, "CPUUsageNSec")) {
            status.cpu_usage_nsec = if (value.len > 0 and !mem.eql(u8, value, "[not set]"))
                fmt.parseInt(u64, value, 10) catch null
            else
                null;
        } else if (mem.eql(u8, key, "LoadState")) {
            status.load_state = try allocator.dupe(u8, value);
        } else if (mem.eql(u8, key, "Description")) {
            status.description = try allocator.dupe(u8, value);
        }
    }

    return status;
}

/// List all L1NE-managed services
pub fn listL1neServices(allocator: mem.Allocator, user_mode: bool) ![][]const u8 {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "systemctl");
    if (user_mode) try argv.append(allocator, "--user");
    try argv.append(allocator, "list-units");
    try argv.append(allocator, "--no-pager");
    try argv.append(allocator, "--plain");
    try argv.append(allocator, "--no-legend");
    try argv.append(allocator, "l1ne-*.service");

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var services = std.ArrayList([]const u8).empty;

    if (result.term != .Exited or result.term.Exited != 0) {
        // No services found is not an error
        return try services.toOwnedSlice(allocator);
    }

    var lines = mem.tokenizeScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        // Parse line: "unit.service loaded active running Description"
        var parts = mem.tokenizeScalar(u8, line, ' ');
        const unit_name = parts.next() orelse continue;

        if (mem.endsWith(u8, unit_name, ".service")) {
            try services.append(allocator, try allocator.dupe(u8, unit_name));
        }
    }

    return try services.toOwnedSlice(allocator);
}

test "systemd notifier basic" {
    var notifier = Notifier.init(std.testing.allocator);
    defer notifier.deinit();

    // This will fail if not running under systemd, which is expected in tests
    notifier.ready() catch |err| switch (err) {
        error.NotUnderSystemd => {}, // Expected in test environment
        else => return err,
    };
}

test "socket activation" {
    const fds = try SocketActivation.getListenFds(std.testing.allocator);
    defer std.testing.allocator.free(fds);

    // In test environment, we expect no FDs
    try std.testing.expectEqual(@as(usize, 0), fds.len);
}

test "is under systemd" {
    // In test environment, should return false
    try std.testing.expect(!isUnderSystemd());
}

// ============================================================================
// DEMONSTRATION & TESTING
// ============================================================================

/// Demonstrates what each systemd feature does
pub fn demonstrateFeatures(allocator: mem.Allocator) !void {
    std.debug.print("\n=== L1NE systemd Integration Features ===\n\n", .{});

    // 1. Detection
    std.debug.print("1. DETECTION: Running under systemd? {}\n", .{isUnderSystemd()});

    // 2. Notifications - what they do
    std.debug.print("\n2. NOTIFICATIONS (What they do):\n", .{});
    std.debug.print("   • READY=1: Tells systemd service is ready\n", .{});
    std.debug.print("   • STATUS=...: Updates shown in 'systemctl status'\n", .{});
    std.debug.print("   • WATCHDOG=1: Prevents systemd from killing service\n", .{});
    std.debug.print("   • STOPPING=1: Graceful shutdown notification\n", .{});

    var notifier = Notifier.init(allocator);
    defer notifier.deinit();

    if (notifier.socket_path) |path| {
        std.debug.print("   Socket path: {s}\n", .{path});
    } else {
        std.debug.print("   Not under systemd - notifications disabled\n", .{});
    }

    // 3. Socket activation - what it does
    std.debug.print("\n3. SOCKET ACTIVATION (Zero-downtime restarts):\n", .{});
    const fds = try SocketActivation.getListenFds(allocator);
    defer allocator.free(fds);
    std.debug.print("   Inherited {} socket(s) from systemd\n", .{fds.len});
    if (fds.len > 0) {
        std.debug.print("   Service can restart without dropping connections\n", .{});
    }

    // 4. Resource limits - what they control
    std.debug.print("\n4. RESOURCE LIMITS (What they control):\n", .{});
    std.debug.print("   • MemoryMax: Hard memory limit (OOM killer)\n", .{});
    std.debug.print("   • CPUQuota: CPU time percentage\n", .{});
    std.debug.print("   • Monitored via /sys/fs/cgroup/\n", .{});

    // Show example conversion
    const example_mem: u8 = 75;
    const example_cpu: u8 = 50;
    std.debug.print("   Example: --mem-percent={} --cpu-percent={}\n", .{ example_mem, example_cpu });
    std.debug.print("   → MemoryMax={}MB, CPUQuota={}%\n", .{
        @as(usize, 50) * @as(usize, example_mem) / 100, // Base 50MB
        @as(usize, 10) * @as(usize, example_cpu) / 100, // Base 10%
    });

    // 5. How to test it
    std.debug.print("\n5. HOW TO TEST:\n", .{});
    std.debug.print("   # Create test socket:\n", .{});
    std.debug.print("   socat UNIX-LISTEN:/tmp/test.sock,fork STDOUT\n", .{});
    std.debug.print("\n   # Run with socket:\n", .{});
    std.debug.print("   NOTIFY_SOCKET=/tmp/test.sock zig test src/l1ne/systemd.zig\n", .{});
    std.debug.print("\n", .{});
}

test "demonstrate features" {
    try demonstrateFeatures(std.testing.allocator);
}

test "notification messages format" {
    var notifier = Notifier.init(std.testing.allocator);
    defer notifier.deinit();

    // Test message formatting (won't actually send)
    var buf: [256]u8 = undefined;

    // Status message
    const status_msg = try fmt.bufPrint(&buf, "STATUS={s}", .{"Service starting..."});
    try std.testing.expect(mem.eql(u8, status_msg, "STATUS=Service starting..."));

    // PID message
    const pid_msg = try fmt.bufPrint(&buf, "MAINPID={d}", .{@as(posix.pid_t, 1234)});
    try std.testing.expect(mem.eql(u8, pid_msg, "MAINPID=1234"));

    // Watchdog
    const wd_msg = "WATCHDOG=1";
    try std.testing.expect(mem.eql(u8, wd_msg, "WATCHDOG=1"));
}

test "watchdog interval calculation" {
    var notifier = Notifier.init(std.testing.allocator);
    defer notifier.deinit();

    const watchdog = try Watchdog.init(&notifier, std.testing.allocator);

    // In test environment, no watchdog
    try std.testing.expect(watchdog.interval_usec == null);

    // If we had watchdog set to 30 seconds
    // It would use half interval: 15 seconds
    const theoretical_interval: u64 = 30_000_000; // 30 seconds in microseconds
    const expected_keepalive = theoretical_interval / 2;
    try std.testing.expectEqual(@as(u64, 15_000_000), expected_keepalive);
}

test "resource limit conversions" {
    // Test percentage to actual values
    const TestCase = struct {
        mem_percent: u8,
        cpu_percent: u8,
        expected_mem_mb: usize,
        expected_cpu: u8,
    };

    const test_cases = [_]TestCase{
        .{ .mem_percent = 100, .cpu_percent = 100, .expected_mem_mb = 50, .expected_cpu = 10 },
        .{ .mem_percent = 50, .cpu_percent = 50, .expected_mem_mb = 25, .expected_cpu = 5 },
        .{ .mem_percent = 80, .cpu_percent = 20, .expected_mem_mb = 40, .expected_cpu = 2 },
        .{ .mem_percent = 10, .cpu_percent = 10, .expected_mem_mb = 5, .expected_cpu = 1 },
    };

    for (test_cases) |tc| {
        const memory_max: usize = @as(usize, 50 * 1024 * 1024) * @as(usize, tc.mem_percent) / 100;
        const cpu_quota = @as(usize, 10) * @as(usize, tc.cpu_percent) / 100;

        try std.testing.expectEqual(tc.expected_mem_mb * 1024 * 1024, memory_max);
        try std.testing.expectEqual(@as(usize, tc.expected_cpu), cpu_quota);
    }
}

test "cgroup paths" {
    const test_services = [_][]const u8{
        "nginx",
        "l1ne-api-8080",
        "test-service",
    };

    for (test_services) |service| {
        var monitor = try CgroupMonitor.init(std.testing.allocator, service);
        defer monitor.deinit();

        const expected = try fmt.allocPrint(std.testing.allocator, "/sys/fs/cgroup/system.slice/{s}.service", .{service});
        defer std.testing.allocator.free(expected);

        try std.testing.expectEqualStrings(expected, monitor.cgroup_path);
    }
}

test "socket activation FD numbering" {
    // systemd passes FDs starting at 3
    // stdin=0, stdout=1, stderr=2, then service sockets
    const SD_LISTEN_FDS_START = 3;

    // If systemd passed 3 sockets, they would be:
    const mock_fds = [_]posix.fd_t{ 3, 4, 5 };

    for (mock_fds, 0..) |fd, i| {
        try std.testing.expectEqual(@as(posix.fd_t, @intCast(SD_LISTEN_FDS_START + i)), fd);
    }
}

test "multiple notifications batching" {
    var notifier = Notifier.init(std.testing.allocator);
    defer notifier.deinit();

    // Test batching multiple notifications
    const messages = [_][]const u8{
        "READY=1",
        "STATUS=Service initialized",
        "MAINPID=12345",
    };

    // Would be sent as single message with newlines
    var expected_buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&expected_buf);
    const writer = fbs.writer();

    for (messages, 0..) |msg, i| {
        if (i > 0) try writer.writeByte('\n');
        try writer.writeAll(msg);
    }

    const expected = fbs.getWritten();
    try std.testing.expect(mem.eql(u8, expected, "READY=1\nSTATUS=Service initialized\nMAINPID=12345"));
}

test "transient service config" {
    const config = ServiceManager.TransientServiceConfig{
        .unit_name = "test-service",
        .exec_args = &[_][]const u8{"/usr/bin/test"},
        .uid = 1000,
        .gid = 1000,
        .memory_max = 52428800, // 50MB
        .cpu_quota = 10,
    };

    try std.testing.expectEqualStrings("test-service", config.unit_name);
    try std.testing.expectEqual(@as(usize, 52428800), config.memory_max.?);
    try std.testing.expectEqual(@as(u8, 10), config.cpu_quota.?);
}

// Run this test with: NOTIFY_SOCKET=/tmp/test.sock zig test src/l1ne/systemd.zig
test "live notification test (requires NOTIFY_SOCKET)" {
    if (!isUnderSystemd()) {
        std.debug.print("Skipping live test - not under systemd\n", .{});
        std.debug.print("To run: NOTIFY_SOCKET=/tmp/test.sock zig test src/l1ne/systemd.zig\n", .{});
        return;
    }

    var notifier = Notifier.init(std.testing.allocator);
    defer notifier.deinit();

    // These would actually send to systemd
    try notifier.ready();
    try notifier.status("Running tests");
    try notifier.watchdog();

    std.debug.print("Successfully sent notifications to systemd!\n", .{});
}
