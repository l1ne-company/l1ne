//! Service Registry for L1NE
//!
//! Tracks state of all service instances in the system.
//!
//! Design principles (TigerStyle):
//!   - Fixed-size array (bounded at 64 services)
//!   - No dynamic allocation
//!   - Explicit state tracking
//!   - Fast lookup by service_id
//!   - All operations O(n) where n <= 64
//!
//! Service states:
//!   - stopped: Service is not running
//!   - running: Service is active
//!
//! Usage:
//!   1. Initialize registry with init()
//!   2. Start services with start_service()
//!   3. Stop services with stop_service()
//!   4. Query state with is_running()

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

/// Maximum services in registry (TigerStyle bound)
pub const max_services: u32 = 64;

/// Service state
pub const ServiceState = enum(u8) {
    stopped = 0,
    running = 1,
};

/// Service record
///
/// Design:
///   - Fixed-size struct
///   - Explicit state tracking
///   - Timestamps for audit trail
pub const ServiceRecord = struct {
    service_id: u32,
    port: u16,
    state: ServiceState,
    started_at_us: u64,
    stopped_at_us: u64,
    _reserved: [6]u8,

    comptime {
        // Ensure struct is reasonably sized
        assert(@sizeOf(ServiceRecord) == 32);
    }

    /// Create a new stopped service record
    ///
    /// Invariants:
    ///   - Pre: service_id is non-zero
    ///   - Pre: port is valid (1024-65535)
    ///   - Post: state is stopped
    ///   - Post: timestamps are zero
    pub fn init(service_id: u32, port: u16) ServiceRecord {
        assert(service_id > 0); // Service ID must be non-zero
        assert(port >= 1024); // Port must be unprivileged
        assert(port <= 65535); // Port must be valid

        return ServiceRecord{
            .service_id = service_id,
            .port = port,
            .state = .stopped,
            .started_at_us = 0,
            .stopped_at_us = 0,
            ._reserved = [_]u8{0} ** 6,
        };
    }
};

/// Service registry
///
/// Design:
///   - Bounded array of 64 service records
///   - Linear search for lookups (fast for small n)
///   - Explicit count tracking
pub const ServiceRegistry = struct {
    services: [max_services]ServiceRecord,
    count: u32,

    /// Initialize empty registry
    ///
    /// Invariants:
    ///   - Post: count is 0
    ///   - Post: all services uninitialized
    pub fn init() ServiceRegistry {
        var registry = ServiceRegistry{
            .services = undefined,
            .count = 0,
        };

        // Initialize all records to stopped
        var i: u32 = 0;
        while (i < max_services) : (i += 1) {
            registry.services[i] = ServiceRecord{
                .service_id = 0,
                .port = 0,
                .state = .stopped,
                .started_at_us = 0,
                .stopped_at_us = 0,
                ._reserved = [_]u8{0} ** 6,
            };
        }

        assert(registry.count == 0); // Count must be zero
        return registry;
    }

    /// Register a new service
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: service_id is non-zero
    ///   - Pre: port is valid (1024-65535)
    ///   - Pre: count < max_services
    ///   - Pre: service_id not already registered
    ///   - Post: count incremented
    ///   - Post: service is stopped state
    pub fn register(self: *ServiceRegistry, service_id: u32, port: u16) !void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(service_id > 0); // Service ID must be non-zero
        assert(port >= 1024); // Port must be unprivileged
        assert(port <= 65535); // Port must be valid

        if (self.count >= max_services) {
            return error.RegistryFull;
        }

        // Check for duplicate
        if (self.find_index(service_id)) |_| {
            return error.ServiceAlreadyRegistered;
        }

        const old_count = self.count;

        // Add to first available slot
        self.services[self.count] = ServiceRecord.init(service_id, port);
        self.count += 1;

        assert(self.count == old_count + 1); // Count incremented
        assert(self.count <= max_services); // Never exceed max
    }

    /// Start a service
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: service_id is non-zero
    ///   - Pre: timestamp_us > 0
    ///   - Pre: service exists in registry
    ///   - Post: service state is running
    ///   - Post: started_at_us is set
    pub fn start_service(
        self: *ServiceRegistry,
        service_id: u32,
        timestamp_us: u64,
    ) !void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(service_id > 0); // Service ID must be non-zero
        assert(timestamp_us > 0); // Timestamp must be non-zero

        const index = self.find_index(service_id) orelse {
            return error.ServiceNotFound;
        };

        assert(index < self.count); // Index must be in bounds

        var service = &self.services[index];

        service.state = .running;
        service.started_at_us = timestamp_us;

        assert(service.state == .running); // State must be running
        assert(service.started_at_us == timestamp_us); // Timestamp set
    }

    /// Stop a service
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: service_id is non-zero
    ///   - Pre: timestamp_us > 0
    ///   - Pre: service exists in registry
    ///   - Post: service state is stopped
    ///   - Post: stopped_at_us is set
    pub fn stop_service(
        self: *ServiceRegistry,
        service_id: u32,
        timestamp_us: u64,
    ) !void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(service_id > 0); // Service ID must be non-zero
        assert(timestamp_us > 0); // Timestamp must be non-zero

        const index = self.find_index(service_id) orelse {
            return error.ServiceNotFound;
        };

        assert(index < self.count); // Index must be in bounds

        var service = &self.services[index];

        service.state = .stopped;
        service.stopped_at_us = timestamp_us;

        assert(service.state == .stopped); // State must be stopped
        assert(service.stopped_at_us == timestamp_us); // Timestamp set
    }

    /// Check if service is running
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: service_id is non-zero
    ///   - Post: returns true if running, false if stopped or not found
    pub fn is_running(self: *const ServiceRegistry, service_id: u32) bool {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(service_id > 0); // Service ID must be non-zero

        const index = self.find_index(service_id) orelse {
            return false;
        };

        assert(index < self.count); // Index must be in bounds

        const service = &self.services[index];
        return service.state == .running;
    }

    /// Get service record by ID
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: service_id is non-zero
    ///   - Post: returns pointer to service if found, null otherwise
    pub fn get_service(
        self: *const ServiceRegistry,
        service_id: u32,
    ) ?*const ServiceRecord {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(service_id > 0); // Service ID must be non-zero

        const index = self.find_index(service_id) orelse {
            return null;
        };

        assert(index < self.count); // Index must be in bounds

        return &self.services[index];
    }

    /// Find service index by ID
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: service_id is non-zero
    ///   - Post: returns index if found, null otherwise
    ///   - Complexity: O(n) where n = count
    fn find_index(self: *const ServiceRegistry, service_id: u32) ?u32 {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(service_id > 0); // Service ID must be non-zero

        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            if (self.services[i].service_id == service_id) {
                assert(i < max_services); // Must be in bounds
                return i;
            }
        }

        return null;
    }

    /// Count running services
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: returned count <= total count
    pub fn count_running(self: *const ServiceRegistry) u32 {
        assert(@intFromPtr(self) != 0); // Self must be valid

        var running: u32 = 0;
        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            if (self.services[i].state == .running) {
                running += 1;
            }
        }

        assert(running <= self.count); // Never exceed total count
        return running;
    }

    /// Clear all services
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: count is 0
    pub fn clear(self: *ServiceRegistry) void {
        assert(@intFromPtr(self) != 0); // Self must be valid

        self.count = 0;

        assert(self.count == 0); // Count must be zero
    }
};
