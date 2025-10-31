//! Scenario Engine for L1NE Simulation Testing
//!
//! Provides orchestration of test scenarios with fault injection.
//!
//! Design principles (TigerStyle):
//!   - Deterministic: Uses PRNG seed for reproducibility
//!   - Bounded: Max 64 services, max 1024 scenario steps
//!   - No allocations: Fixed-size structures
//!   - Composable: Build scenarios from config
//!
//! Integration Flow:
//!
//!   ┌─────────────────┐
//!   │  scenario.nix   │  (User writes test scenario)
//!   └────────┬────────┘
//!            │
//!            ▼
//!   ┌─────────────────┐
//!   │scenario_config  │  (Parse Nix → Config)
//!   └────────┬────────┘
//!            │
//!            ▼
//!   ┌─────────────────┐
//!   │  ScenarioRunner │  (Execute scenario)
//!   │  - PRNG (seed)  │
//!   │  - Simulator    │
//!   │  - FaultInjector│
//!   └────────┬────────┘
//!            │
//!            ▼
//!   ┌─────────────────┐
//!   │   WAL Events    │  (Generate events)
//!   └────────┬────────┘
//!            │
//!            ▼
//!   ┌─────────────────┐
//!   │  Verification   │  (Check invariants)
//!   │  + Metrics      │  (Collect stats)
//!   └────────┬────────┘
//!            │
//!            ▼
//!   ┌─────────────────┐
//!   │  JSON Output    │  (std.json.Stringify)
//!   └─────────────────┘
//!
//! Components:
//!   - ServiceConfig: Service to start in scenario
//!   - ScenarioConfig: Overall scenario configuration
//!   - ScenarioRunner: Executes scenario with simulation
//!   - Built-in scenarios: Common test patterns
//!
//! Usage:
//!   var scenario = ScenarioConfig.init("load-test");
//!   try scenario.add_service(1, 8080);
//!   scenario.duration_us = 60_000_000;  // 60 seconds
//!
//!   var runner = try ScenarioRunner.init(scenario, 12345);
//!   try runner.run();

const std = @import("std");
const assert = std.debug.assert;
const prng_mod = @import("prng.zig");
const fault_injector_mod = @import("fault_injector.zig");
const simulator_mod = @import("simulator.zig");
const wal = @import("wal.zig");
const time_mod = @import("time.zig");

/// Maximum services in scenario (TigerStyle bound)
pub const max_scenario_services: u32 = 64;

/// Maximum scenario steps (TigerStyle bound)
pub const max_scenario_steps: u32 = 1024;

/// Service configuration for scenario
pub const ServiceConfig = struct {
    service_id: u32,
    port: u16,
    start_delay_us: u64, // Delay before starting service

    /// Create service config
    ///
    /// Invariants:
    ///   - Pre: service_id > 0
    ///   - Pre: port >= 1024
    ///   - Post: all fields initialized
    pub fn init(service_id: u32, port: u16) ServiceConfig {
        assert(service_id > 0); // Service ID must be valid
        assert(port >= 1024); // Port must be unprivileged

        return ServiceConfig{
            .service_id = service_id,
            .port = port,
            .start_delay_us = 0,
        };
    }
};

/// Scenario type
pub const ScenarioType = enum(u8) {
    load_test = 1,        // High traffic load
    chaos_test = 2,       // Random failures
    transaction_stress = 3, // Many concurrent transactions
    lifecycle_test = 4,   // Service start/stop patterns
    custom = 5,          // User-defined
};

/// Scenario configuration
pub const ScenarioConfig = struct {
    name: []const u8,
    scenario_type: ScenarioType,
    services: [max_scenario_services]ServiceConfig,
    service_count: u32,
    duration_us: u64,
    seed: u64,
    fault_config: fault_injector_mod.FaultConfig,

    /// Create new scenario
    ///
    /// Invariants:
    ///   - Pre: name is valid string
    ///   - Post: service_count is 0
    ///   - Post: duration_us is 0
    pub fn init(name: []const u8, scenario_type: ScenarioType) ScenarioConfig {
        assert(name.len > 0); // Name must not be empty

        return ScenarioConfig{
            .name = name,
            .scenario_type = scenario_type,
            .services = undefined,
            .service_count = 0,
            .duration_us = 0,
            .seed = 0,
            .fault_config = fault_injector_mod.FaultConfig{},
        };
    }

    /// Add service to scenario
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: service_id > 0
    ///   - Pre: port >= 1024
    ///   - Pre: service_count < max_scenario_services
    ///   - Post: service_count incremented
    pub fn add_service(
        self: *ScenarioConfig,
        service_id: u32,
        port: u16,
    ) !void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(service_id > 0); // Service ID must be valid
        assert(port >= 1024); // Port must be unprivileged

        if (self.service_count >= max_scenario_services) {
            return error.TooManyServices;
        }

        const old_count = self.service_count;

        self.services[self.service_count] = ServiceConfig.init(service_id, port);
        self.service_count += 1;

        assert(self.service_count == old_count + 1); // Count incremented
        assert(self.service_count <= max_scenario_services); // Within bounds
    }
};

/// Scenario execution result
pub const ScenarioResult = struct {
    success: bool,
    events_processed: u64,
    faults_injected: u64,
    services_started: u32,
    services_stopped: u32,
    duration_us: u64,
    error_message: ?[]const u8,
};

/// Scenario Runner
///
/// Design:
///   - Owns simulator, fault injector, PRNG
///   - Executes scenario deterministically
///   - Tracks execution state
pub const ScenarioRunner = struct {
    config: ScenarioConfig,
    prng: prng_mod.PRNG,
    fault_injector: fault_injector_mod.FaultInjector,
    clock: time_mod.Clock,
    simulator: simulator_mod.Simulator,
    events_generated: u64,
    start_time_us: u64,

    /// Initialize scenario runner
    ///
    /// Invariants:
    ///   - Pre: config is valid
    ///   - Pre: seed is non-zero for determinism
    ///   - Post: all components initialized
    pub fn init(config: ScenarioConfig, seed: u64) ScenarioRunner {
        assert(config.name.len > 0); // Name must be valid
        assert(seed > 0); // Seed must be non-zero

        const start_time = 1_000_000; // Start at 1 second

        // Configure fault injector
        var fault_injector = fault_injector_mod.FaultInjector.init();
        fault_injector.configure(config.fault_config);

        // Initialize runner with clock, then create simulator with clock pointer
        var runner = ScenarioRunner{
            .config = config,
            .prng = prng_mod.PRNG.init(seed),
            .fault_injector = fault_injector,
            .clock = time_mod.Clock.init_simulated(start_time),
            .simulator = undefined,
            .events_generated = 0,
            .start_time_us = start_time,
        };
        runner.simulator = simulator_mod.Simulator.init(&runner.clock);

        return runner;
    }

    /// Run scenario
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: simulator has processed all events
    ///   - Post: result contains execution summary
    pub fn run(self: *ScenarioRunner) !ScenarioResult {
        assert(@intFromPtr(self) != 0); // Self must be valid

        const execution_start = self.clock.now().microseconds;

        // Generate initial service start events
        try self.generate_service_starts();

        // Generate scenario-specific events
        switch (self.config.scenario_type) {
            .load_test => try self.run_load_test(),
            .chaos_test => try self.run_chaos_test(),
            .transaction_stress => try self.run_transaction_stress(),
            .lifecycle_test => try self.run_lifecycle_test(),
            .custom => try self.run_custom(),
        }

        // Replay all events
        while (self.simulator.has_next()) {
            try self.simulator.replay_next();
            self.events_generated += 1;
        }

        const execution_end = self.clock.now().microseconds;
        const duration = execution_end - execution_start;

        return ScenarioResult{
            .success = true,
            .events_processed = self.events_generated,
            .faults_injected = self.fault_injector.total_faults_injected(),
            .services_started = self.simulator.state.services_started,
            .services_stopped = self.simulator.state.services_stopped,
            .duration_us = duration,
            .error_message = null,
        };
    }

    /// Generate service start events
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: start events loaded into simulator
    fn generate_service_starts(self: *ScenarioRunner) !void {
        assert(@intFromPtr(self) != 0); // Self must be valid

        var i: u32 = 0;
        while (i < self.config.service_count) : (i += 1) {
            const service = self.config.services[i];
            const timestamp = self.start_time_us + service.start_delay_us;

            var payload_struct = wal.ServiceStartPayload{
                .service_id = service.service_id,
                .port = service.port,
                ._reserved = [_]u8{0} ** 122,
            };
            const payload_bytes = std.mem.asBytes(&payload_struct);
            const entry = wal.create_entry(
                timestamp,
                .service_start,
                payload_bytes[0..128].*,
            );
            try self.simulator.load_event(&entry);
        }
    }

    /// Run load test scenario
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: load test events generated
    fn run_load_test(self: *ScenarioRunner) !void {
        assert(@intFromPtr(self) != 0); // Self must be valid

        const end_time = self.start_time_us + self.config.duration_us;
        var current_time = self.start_time_us;

        // Generate proxy accept/close events for load
        while (current_time < end_time) {
            const service_id = self.prng.next_range(1, self.config.service_count);
            const connection_id = self.events_generated + 1;

            // Accept
            var accept_payload = wal.ProxyAcceptPayload{
                .connection_id = connection_id,
                .service_id = service_id,
                .client_port = 12345,
                ._reserved = [_]u8{0} ** 114,
            };
            const accept_bytes = std.mem.asBytes(&accept_payload);
            const accept_entry = wal.create_entry(
                current_time,
                .proxy_accept,
                accept_bytes[0..128].*,
            );
            try self.simulator.load_event(&accept_entry);

            // Close after 100ms
            current_time += 100_000;
            var close_payload = wal.ProxyClosePayload{
                .connection_id = connection_id,
                .bytes_sent = 1024,
                .bytes_received = 512,
                ._reserved = [_]u8{0} ** 104,
            };
            const close_bytes = std.mem.asBytes(&close_payload);
            const close_entry = wal.create_entry(
                current_time,
                .proxy_close,
                close_bytes[0..128].*,
            );
            try self.simulator.load_event(&close_entry);

            current_time += 10_000; // 10ms between requests
        }
    }

    /// Run chaos test scenario
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: chaos events with faults generated
    fn run_chaos_test(self: *ScenarioRunner) !void {
        assert(@intFromPtr(self) != 0); // Self must be valid

        const end_time = self.start_time_us + self.config.duration_us;
        var current_time = self.start_time_us;

        while (current_time < end_time) {
            const service_id = self.prng.next_range(1, self.config.service_count);

            // Check if crash should be injected
            if (self.fault_injector.should_inject_crash(&self.prng, service_id, current_time)) {
                // Generate service stop (crash)
                var stop_payload = wal.ServiceStopPayload{
                    .service_id = service_id,
                    .exit_code = -1, // Crash exit code
                    ._reserved = [_]u8{0} ** 120,
                };
                const stop_bytes = std.mem.asBytes(&stop_payload);
                const stop_entry = wal.create_entry(
                    current_time,
                    .service_stop,
                    stop_bytes[0..128].*,
                );
                try self.simulator.load_event(&stop_entry);

                // Restart after 1 second
                current_time += 1_000_000;
                var start_payload = wal.ServiceStartPayload{
                    .service_id = service_id,
                    .port = 8000 + @as(u16, @intCast(service_id)),
                    ._reserved = [_]u8{0} ** 122,
                };
                const start_bytes = std.mem.asBytes(&start_payload);
                const start_entry = wal.create_entry(
                    current_time,
                    .service_start,
                    start_bytes[0..128].*,
                );
                try self.simulator.load_event(&start_entry);
            }

            current_time += 100_000; // 100ms between checks
        }
    }

    /// Run transaction stress scenario
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: transaction events generated
    fn run_transaction_stress(self: *ScenarioRunner) !void {
        assert(@intFromPtr(self) != 0); // Self must be valid

        const end_time = self.start_time_us + self.config.duration_us;
        var current_time = self.start_time_us;
        var tx_id: u64 = 1;

        while (current_time < end_time) {
            const event_count = self.prng.next_range(2, 10);

            // TX_BEGIN
            const begin_entry = wal.create_tx_begin_entry(
                current_time,
                tx_id,
                event_count,
            );
            try self.simulator.load_event(&begin_entry);
            current_time += 1000;

            // Events
            var i: u32 = 0;
            while (i < event_count) : (i += 1) {
                const service_id = self.prng.next_range(1, self.config.service_count);
                var start_payload = wal.ServiceStartPayload{
                    .service_id = service_id,
                    .port = 9000,
                    ._reserved = [_]u8{0} ** 122,
                };
                const start_bytes = std.mem.asBytes(&start_payload);
                const start_entry = wal.create_entry(
                    current_time,
                    .service_start,
                    start_bytes[0..128].*,
                );
                try self.simulator.load_event(&start_entry);
                current_time += 500;
            }

            // TX_COMMIT (90% commit, 10% abort)
            if (self.prng.next_bool(0.9)) {
                const commit_entry = wal.create_tx_commit_entry(
                    current_time,
                    tx_id,
                    event_count,
                );
                try self.simulator.load_event(&commit_entry);
            } else {
                const abort_entry = wal.create_tx_abort_entry(
                    current_time,
                    tx_id,
                    1, // reason_code
                );
                try self.simulator.load_event(&abort_entry);
            }

            tx_id += 1;
            current_time += 10_000; // 10ms between transactions
        }
    }

    /// Run lifecycle test scenario
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: lifecycle events generated
    fn run_lifecycle_test(self: *ScenarioRunner) !void {
        assert(@intFromPtr(self) != 0); // Self must be valid

        // Simple pattern: start, run, stop each service
        var i: u32 = 0;
        while (i < self.config.service_count) : (i += 1) {
            const service = self.config.services[i];
            var current_time = self.start_time_us + (i * 1_000_000); // 1s apart

            // Start
            var start_payload = wal.ServiceStartPayload{
                .service_id = service.service_id,
                .port = service.port,
                ._reserved = [_]u8{0} ** 122,
            };
            const start_bytes = std.mem.asBytes(&start_payload);
            const start_entry = wal.create_entry(
                current_time,
                .service_start,
                start_bytes[0..128].*,
            );
            try self.simulator.load_event(&start_entry);

            // Stop after 5 seconds
            current_time += 5_000_000;
            var stop_payload = wal.ServiceStopPayload{
                .service_id = service.service_id,
                .exit_code = 0,
                ._reserved = [_]u8{0} ** 120,
            };
            const stop_bytes = std.mem.asBytes(&stop_payload);
            const stop_entry = wal.create_entry(
                current_time,
                .service_stop,
                stop_bytes[0..128].*,
            );
            try self.simulator.load_event(&stop_entry);
        }
    }

    /// Run custom scenario
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: custom events generated (placeholder)
    fn run_custom(self: *ScenarioRunner) !void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        // Custom scenarios implemented by user
        // This is a placeholder for extension
    }
};
