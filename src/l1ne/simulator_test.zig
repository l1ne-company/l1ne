//! Comprehensive tests for Simulator
//!
//! These tests verify:
//! - Event loading from WAL entries
//! - Deterministic replay
//! - State tracking
//! - Time advancement
//! - Invariant checking

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const simulator = @import("simulator.zig");
const wal = @import("wal.zig");
const time_mod = @import("time.zig");
const service_registry = @import("service_registry.zig");

// Test: State initialization

// Verifies:
//   - State starts with zero counts
//   - All fields initialized
test "Simulator State: initialization" {
    const state = simulator.State.init();

    try testing.expectEqual(@as(u32, 0), state.services_started);
    try testing.expectEqual(@as(u32, 0), state.services_stopped);
    try testing.expectEqual(@as(u64, 0), state.connections_opened);
    try testing.expectEqual(@as(u64, 0), state.connections_closed);
    try testing.expectEqual(@as(u64, 0), state.bytes_sent_total);
    try testing.expectEqual(@as(u64, 0), state.bytes_received_total);
}

// Test: State active services calculation

// Verifies:
//   - Active services = started - stopped
//   - Calculation is correct
test "Simulator State: active services" {
    var state = simulator.State.init();
    var registry = service_registry.ServiceRegistry.init();

    // Start 3 services
    const start_event = simulator.Event{
        .timestamp_us = 1_001_000,
        .event_type = .service_start,
        .data = .{ .service_start = .{ .service_id = 1, .port = 8080 } },
    };

    state.apply_event(&start_event, &registry);
    state.apply_event(&start_event, &registry);
    state.apply_event(&start_event, &registry);

    try testing.expectEqual(@as(u32, 3), state.active_services());

    // Stop 1 service
    const stop_event = simulator.Event{
        .timestamp_us = 1_002_000,
        .event_type = .service_stop,
        .data = .{ .service_stop = .{ .service_id = 1, .exit_code = 0 } },
    };

    state.apply_event(&stop_event, &registry);

    try testing.expectEqual(@as(u32, 2), state.active_services());
}

// Test: State active connections calculation

// Verifies:
//   - Active connections = opened - closed
//   - Calculation is correct
test "Simulator State: active connections" {
    var state = simulator.State.init();
    var registry = service_registry.ServiceRegistry.init();

    // Open 5 connections
    const accept_event = simulator.Event{
        .timestamp_us = 1_001_000,
        .event_type = .proxy_accept,
        .data = .{ .proxy_accept = .{ .connection_id = 1, .service_id = 1, .client_port = 12345 } },
    };

    var i: u64 = 0;
    while (i < 5) : (i += 1) {
        state.apply_event(&accept_event, &registry);
    }

    try testing.expectEqual(@as(u64, 5), state.active_connections());

    // Close 2 connections
    const close_event = simulator.Event{
        .timestamp_us = 1_002_000,
        .event_type = .proxy_close,
        .data = .{ .proxy_close = .{ .connection_id = 1, .bytes_sent = 100, .bytes_received = 200 } },
    };

    state.apply_event(&close_event, &registry);
    state.apply_event(&close_event, &registry);

    try testing.expectEqual(@as(u64, 3), state.active_connections());
}

// Test: State byte counters

// Verifies:
//   - Bytes sent/received accumulate correctly
//   - Counters only increase
test "Simulator State: byte counters" {
    var state = simulator.State.init();
    var registry = service_registry.ServiceRegistry.init();

    const close_event1 = simulator.Event{
        .timestamp_us = 1_001_000,
        .event_type = .proxy_close,
        .data = .{ .proxy_close = .{ .connection_id = 1, .bytes_sent = 1000, .bytes_received = 2000 } },
    };

    const close_event2 = simulator.Event{
        .timestamp_us = 1_002_000,
        .event_type = .proxy_close,
        .data = .{ .proxy_close = .{ .connection_id = 2, .bytes_sent = 500, .bytes_received = 1500 } },
    };

    state.apply_event(&close_event1, &registry);
    try testing.expectEqual(@as(u64, 1000), state.bytes_sent_total);
    try testing.expectEqual(@as(u64, 2000), state.bytes_received_total);

    state.apply_event(&close_event2, &registry);
    try testing.expectEqual(@as(u64, 1500), state.bytes_sent_total);
    try testing.expectEqual(@as(u64, 3500), state.bytes_received_total);
}

// Test: Simulator initialization

// Verifies:
//   - Simulator starts empty
//   - Clock is in simulated mode
test "Simulator: initialization" {
    var clock = time_mod.Clock.init_simulated(1_000_000);
    const sim = simulator.Simulator.init(&clock);

    try testing.expectEqual(@as(u32, 0), sim.event_count);
    try testing.expectEqual(@as(u32, 0), sim.current_event);
    try testing.expect(!sim.has_next());
}

// Test: Load single event

// Verifies:
//   - Can load WAL entry
//   - Event count increments
test "Simulator: load single event" {
    var clock = time_mod.Clock.init_simulated(1_000_000);
    var sim = simulator.Simulator.init(&clock);

    // Create WAL entry
    var payload_struct = wal.ServiceStartPayload{
        .service_id = 42,
        .port = 8080,
        ._reserved = [_]u8{0} ** 122,
    };
    const payload_bytes = std.mem.asBytes(&payload_struct);
    const entry = wal.create_entry(1000, .service_start, payload_bytes[0..128].*);

    try sim.load_event(&entry);

    try testing.expectEqual(@as(u32, 1), sim.event_count);
    try testing.expect(sim.has_next());
}

// Test: Load multiple events

// Verifies:
//   - Can load many events
//   - Count tracks correctly
test "Simulator: load multiple events" {
    var clock = time_mod.Clock.init_simulated(1_000_000);
    var sim = simulator.Simulator.init(&clock);

    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        var payload_struct = wal.ServiceStartPayload{
            .service_id = @intCast(i + 1), // Start from 1, not 0
            .port = 8080,
            ._reserved = [_]u8{0} ** 122,
        };
        const payload_bytes = std.mem.asBytes(&payload_struct);
        const timestamp = 1_001_000 + i * 100;
        const entry = wal.create_entry(timestamp, .service_start, payload_bytes[0..128].*);

        try sim.load_event(&entry);
    }

    try testing.expectEqual(@as(u32, 10), sim.event_count);
    try testing.expect(sim.has_next());
}

// Test: Replay single event

// Verifies:
//   - Event replay updates state
//   - Clock advances to event timestamp
test "Simulator: replay single event" {
    var clock = time_mod.Clock.init_simulated(1_000_000);
    var sim = simulator.Simulator.init(&clock);

    var payload_struct = wal.ServiceStartPayload{
        .service_id = 42,
        .port = 8080,
        ._reserved = [_]u8{0} ** 122,
    };
    const payload_bytes = std.mem.asBytes(&payload_struct);
    const entry = wal.create_entry(2_000_000, .service_start, payload_bytes[0..128].*);

    try sim.load_event(&entry);
    try sim.replay_next();

    try testing.expectEqual(@as(u32, 1), sim.state.services_started);
    try testing.expectEqual(@as(u32, 1), sim.current_event);
    try testing.expect(!sim.has_next());

    // Verify clock advanced
    try testing.expectEqual(@as(u64, 2_000_000), clock.simulated_time_us);
}

// Test: Replay multiple events

// Verifies:
//   - All events replay in order
//   - State updates correctly
test "Simulator: replay multiple events" {
    var clock = time_mod.Clock.init_simulated(1_000_000);
    var sim = simulator.Simulator.init(&clock);

    // Load 5 service start events
    var i: u64 = 0;
    while (i < 5) : (i += 1) {
        var payload_struct = wal.ServiceStartPayload{
            .service_id = @intCast(i + 1), // Start from 1, not 0
            .port = 8080,
            ._reserved = [_]u8{0} ** 122,
        };
        const payload_bytes = std.mem.asBytes(&payload_struct);
        const timestamp = 1_001_000 + i * 1000;
        const entry = wal.create_entry(timestamp, .service_start, payload_bytes[0..128].*);
        try sim.load_event(&entry);
    }

    // Replay all events
    while (sim.has_next()) {
        try sim.replay_next();
    }

    try testing.expectEqual(@as(u32, 5), sim.state.services_started);
    try testing.expectEqual(@as(u32, 5), sim.current_event);
}

// Test: Simulator reset

// Verifies:
//   - Reset clears current position
//   - State is cleared
//   - Events remain loaded
test "Simulator: reset" {
    var clock = time_mod.Clock.init_simulated(1_000_000);
    var sim = simulator.Simulator.init(&clock);

    // Load and replay events
    var i: u64 = 0;
    while (i < 3) : (i += 1) {
        var payload_struct = wal.ServiceStartPayload{
            .service_id = @intCast(i + 1), // Start from 1, not 0
            .port = 8080,
            ._reserved = [_]u8{0} ** 122,
        };
        const payload_bytes = std.mem.asBytes(&payload_struct);
        const entry = wal.create_entry(1_001_000 + i * 100, .service_start, payload_bytes[0..128].*);
        try sim.load_event(&entry);
    }

    while (sim.has_next()) {
        try sim.replay_next();
    }

    try testing.expectEqual(@as(u32, 3), sim.state.services_started);

    // Reset
    sim.reset();

    try testing.expectEqual(@as(u32, 0), sim.current_event);
    try testing.expectEqual(@as(u32, 0), sim.state.services_started);
    try testing.expectEqual(@as(u32, 3), sim.event_count); // Events still loaded
    try testing.expect(sim.has_next());
}

// Test: Event type preservation

// Verifies:
//   - All event types decode correctly
//   - Types match WAL entry types
test "Simulator: event type preservation" {
    var clock = time_mod.Clock.init_simulated(1_000_000);
    var sim = simulator.Simulator.init(&clock);

    // Service start
    {
        var payload = wal.ServiceStartPayload{ .service_id = 1, .port = 8080, ._reserved = [_]u8{0} ** 122 };
        const bytes = std.mem.asBytes(&payload);
        const entry = wal.create_entry(1_001_000, .service_start, bytes[0..128].*);
        try sim.load_event(&entry);
    }

    // Service stop
    {
        var payload = wal.ServiceStopPayload{ .service_id = 1, .exit_code = 0, ._reserved = [_]u8{0} ** 120 };
        const bytes = std.mem.asBytes(&payload);
        const entry = wal.create_entry(1_002_000, .service_stop, bytes[0..128].*);
        try sim.load_event(&entry);
    }

    // Proxy accept
    {
        var payload = wal.ProxyAcceptPayload{ .connection_id = 1, .service_id = 1, .client_port = 12345, ._reserved = [_]u8{0} ** 114 };
        const bytes = std.mem.asBytes(&payload);
        const entry = wal.create_entry(1_003_000, .proxy_accept, bytes[0..128].*);
        try sim.load_event(&entry);
    }

    // Proxy close
    {
        var payload = wal.ProxyClosePayload{ .connection_id = 1, .bytes_sent = 100, .bytes_received = 200, ._reserved = [_]u8{0} ** 104 };
        const bytes = std.mem.asBytes(&payload);
        const entry = wal.create_entry(1_004_000, .proxy_close, bytes[0..128].*);
        try sim.load_event(&entry);
    }

    try testing.expectEqual(@as(u32, 4), sim.event_count);

    // Replay and verify types
    try sim.replay_next();
    try testing.expectEqual(@as(u32, 1), sim.state.services_started);

    try sim.replay_next();
    try testing.expectEqual(@as(u32, 1), sim.state.services_stopped);

    try sim.replay_next();
    try testing.expectEqual(@as(u64, 1), sim.state.connections_opened);

    try sim.replay_next();
    try testing.expectEqual(@as(u64, 1), sim.state.connections_closed);
}
