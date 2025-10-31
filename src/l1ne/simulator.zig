//! Deterministic Simulator for L1NE
//!
//! Provides deterministic replay of WAL entries for testing and verification.
//!
//! Design principles (TigerStyle):
//!   - Sequential event replay (no concurrency in simulation)
//!   - Bounded event queue (fixed size)
//!   - Explicit state tracking
//!   - No allocations during replay
//!   - All timing deterministic
//!
//! Usage:
//!   1. Load WAL entries
//!   2. Replay events in timestamp order
//!   3. Verify system state transitions
//!   4. Check invariants at each step

const std = @import("std");
const assert = std.debug.assert;
const wal = @import("wal.zig");
const time_mod = @import("time.zig");
const types = @import("types.zig");
const service_registry = @import("service_registry.zig");

/// Maximum events in simulation queue
pub const max_events: u32 = 1024;

/// Maximum events per transaction (TigerStyle bound)
pub const max_events_per_tx: u32 = 64;

/// Simulation event (decoded WAL entry)
pub const Event = struct {
    timestamp_us: u64,
    event_type: EventType,
    data: EventData,
};

/// Event type discriminator
pub const EventType = enum(u8) {
    service_start = 1,
    service_stop = 2,
    proxy_accept = 3,
    proxy_close = 4,
    config_reload = 5,
    checkpoint = 6,
    tx_begin = 7,
    tx_commit = 8,
    tx_abort = 9,
};

/// Event data union
pub const EventData = union(EventType) {
    service_start: ServiceStartData,
    service_stop: ServiceStopData,
    proxy_accept: ProxyAcceptData,
    proxy_close: ProxyCloseData,
    config_reload: void,
    checkpoint: void,
    tx_begin: TxBeginData,
    tx_commit: TxCommitData,
    tx_abort: TxAbortData,
};

/// Service start event data
pub const ServiceStartData = struct {
    service_id: u32,
    port: u16,
};

/// Service stop event data
pub const ServiceStopData = struct {
    service_id: u32,
    exit_code: i32,
};

/// Proxy accept event data
pub const ProxyAcceptData = struct {
    connection_id: u64,
    service_id: u32,
    client_port: u16,
};

/// Proxy close event data
pub const ProxyCloseData = struct {
    connection_id: u64,
    bytes_sent: u64,
    bytes_received: u64,
};

/// Transaction begin event data
pub const TxBeginData = struct {
    tx_id: u64,
    event_count: u32,
};

/// Transaction commit event data
pub const TxCommitData = struct {
    tx_id: u64,
    event_count: u32,
};

/// Transaction abort event data
pub const TxAbortData = struct {
    tx_id: u64,
    reason_code: u32,
};

/// Simulation state
///
/// Design:
///   - Tracks all active services and connections
///   - Bounded arrays (no dynamic allocation)
///   - Explicit counts for validation
pub const State = struct {
    services_started: u32,
    services_stopped: u32,
    connections_opened: u64,
    connections_closed: u64,
    bytes_sent_total: u64,
    bytes_received_total: u64,

    /// Initialize empty state
    pub fn init() State {
        return State{
            .services_started = 0,
            .services_stopped = 0,
            .connections_opened = 0,
            .connections_closed = 0,
            .bytes_sent_total = 0,
            .bytes_received_total = 0,
        };
    }

    /// Apply event to state (with registry)
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: event is valid pointer
    ///   - Pre: registry is valid pointer
    ///   - Post: state updated based on event type
    ///   - Post: counts never decrease
    pub fn apply_event(
        self: *State,
        event: *const Event,
        registry: *service_registry.ServiceRegistry,
    ) void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(@intFromPtr(event) != 0); // Event must be valid
        assert(@intFromPtr(registry) != 0); // Registry must be valid

        const old_started = self.services_started;
        const old_stopped = self.services_stopped;
        const old_opened = self.connections_opened;
        const old_closed = self.connections_closed;

        switch (event.data) {
            .service_start => |data| {
                self.services_started += 1;
                // Update registry if service exists
                registry.start_service(data.service_id, event.timestamp_us) catch {};
            },
            .service_stop => |data| {
                self.services_stopped += 1;
                // Update registry if service exists
                registry.stop_service(data.service_id, event.timestamp_us) catch {};
            },
            .proxy_accept => |data| {
                _ = data;
                self.connections_opened += 1;
            },
            .proxy_close => |data| {
                self.connections_closed += 1;
                self.bytes_sent_total += data.bytes_sent;
                self.bytes_received_total += data.bytes_received;
            },
            .config_reload => {},
            .checkpoint => {},
            .tx_begin => |data| {
                _ = data;
                // Transaction begin - no state change
            },
            .tx_commit => |data| {
                _ = data;
                // Transaction commit - handled by Simulator
            },
            .tx_abort => |data| {
                _ = data;
                // Transaction abort - handled by Simulator
            },
        }

        // Verify counts increased correctly
        assert(self.services_started >= old_started); // Never decreases
        assert(self.services_stopped >= old_stopped); // Never decreases
        assert(self.connections_opened >= old_opened); // Never decreases
        assert(self.connections_closed >= old_closed); // Never decreases
    }

    /// Get count of currently active services
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: returned value >= 0
    pub fn active_services(self: *const State) u32 {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(self.services_started >= self.services_stopped); // Cannot stop more than started

        const active = self.services_started - self.services_stopped;
        assert(active >= 0); // Must be non-negative
        return active;
    }

    /// Get count of currently active connections
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: returned value >= 0
    pub fn active_connections(self: *const State) u64 {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(self.connections_opened >= self.connections_closed); // Cannot close more than opened

        const active = self.connections_opened - self.connections_closed;
        assert(active >= 0); // Must be non-negative
        return active;
    }
};

/// Simulator instance
///
/// Design:
///   - Loads events from WAL
///   - Replays in timestamp order
///   - Maintains simulation state
///   - Provides hooks for verification
///   - Supports transactional event replay
pub const Simulator = struct {
    events: [max_events]Event,
    event_count: u32,
    current_event: u32,
    state: State,
    clock: *time_mod.Clock,
    registry: service_registry.ServiceRegistry,

    // Transaction state
    in_transaction: bool,
    current_tx_id: u64,
    pending_events: [max_events_per_tx]Event,
    pending_count: u32,

    /// Initialize simulator with simulated clock
    ///
    /// Invariants:
    ///   - Pre: clock is valid pointer
    ///   - Pre: clock is in simulated mode
    ///   - Post: simulator is empty (0 events)
    ///   - Post: no transaction in progress
    pub fn init(clock: *time_mod.Clock) Simulator {
        assert(@intFromPtr(clock) != 0); // Clock must be valid
        assert(clock.mode == .simulated); // Must be simulated mode

        return Simulator{
            .events = undefined,
            .event_count = 0,
            .current_event = 0,
            .state = State.init(),
            .clock = clock,
            .registry = service_registry.ServiceRegistry.init(),
            .in_transaction = false,
            .current_tx_id = 0,
            .pending_events = undefined,
            .pending_count = 0,
        };
    }

    /// Load event from WAL entry
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: entry is valid pointer
    ///   - Pre: event_count < max_events
    ///   - Post: event added to events array
    ///   - Post: event_count incremented
    pub fn load_event(self: *Simulator, entry: *const wal.Entry) !void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(@intFromPtr(entry) != 0); // Entry must be valid
        assert(self.event_count < max_events); // Must have space

        const old_count = self.event_count;

        // Decode entry into event
        const event = try decode_entry(entry);

        self.events[self.event_count] = event;
        self.event_count += 1;

        assert(self.event_count == old_count + 1); // Count increased
        assert(self.event_count <= max_events); // Within bounds
    }

    /// Replay next event (with transaction support)
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: has_next() returns true
    ///   - Post: current_event incremented
    ///   - Post: state updated (unless buffered in transaction)
    ///   - Post: clock advanced to event timestamp
    pub fn replay_next(self: *Simulator) !void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(self.has_next()); // Must have events remaining

        const old_current = self.current_event;
        const event = &self.events[self.current_event];

        // Advance clock to event timestamp
        self.clock.set_time(event.timestamp_us);

        // Handle transaction events
        switch (event.data) {
            .tx_begin => |data| {
                try self.begin_transaction(data.tx_id, data.event_count);
            },
            .tx_commit => |data| {
                try self.commit_transaction(data.tx_id);
            },
            .tx_abort => |data| {
                try self.abort_transaction(data.tx_id);
            },
            else => {
                // Regular event - apply or buffer
                if (self.in_transaction) {
                    try self.buffer_event(event);
                } else {
                    self.state.apply_event(event, &self.registry);
                }
            },
        }

        self.current_event += 1;

        assert(self.current_event == old_current + 1); // Advanced by 1
        assert(self.current_event <= self.event_count); // Within bounds
    }

    /// Begin transaction
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: tx_id is non-zero
    ///   - Pre: not already in transaction
    ///   - Post: in_transaction is true
    ///   - Post: current_tx_id is set
    fn begin_transaction(self: *Simulator, tx_id: u64, event_count: u32) !void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(tx_id > 0); // TX ID must be non-zero
        assert(!self.in_transaction); // Cannot nest transactions

        if (event_count > max_events_per_tx) {
            return error.TransactionTooLarge;
        }

        self.in_transaction = true;
        self.current_tx_id = tx_id;
        self.pending_count = 0;

        assert(self.in_transaction); // Must be in transaction
        assert(self.current_tx_id == tx_id); // TX ID must match
    }

    /// Buffer event in transaction
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: event is valid pointer
    ///   - Pre: in_transaction is true
    ///   - Pre: pending_count < max_events_per_tx
    ///   - Post: pending_count incremented
    fn buffer_event(self: *Simulator, event: *const Event) !void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(@intFromPtr(event) != 0); // Event must be valid
        assert(self.in_transaction); // Must be in transaction

        if (self.pending_count >= max_events_per_tx) {
            return error.TransactionBufferFull;
        }

        const old_count = self.pending_count;

        self.pending_events[self.pending_count] = event.*;
        self.pending_count += 1;

        assert(self.pending_count == old_count + 1); // Count increased
    }

    /// Commit transaction (apply all buffered events atomically)
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: tx_id matches current_tx_id
    ///   - Pre: in_transaction is true
    ///   - Post: all pending events applied
    ///   - Post: in_transaction is false
    fn commit_transaction(self: *Simulator, tx_id: u64) !void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(tx_id > 0); // TX ID must be non-zero
        assert(self.in_transaction); // Must be in transaction

        if (tx_id != self.current_tx_id) {
            return error.TransactionIdMismatch;
        }

        // Apply all pending events atomically
        var i: u32 = 0;
        while (i < self.pending_count) : (i += 1) {
            const event = &self.pending_events[i];
            self.state.apply_event(event, &self.registry);
        }

        // Clear transaction state
        self.in_transaction = false;
        self.current_tx_id = 0;
        self.pending_count = 0;

        assert(!self.in_transaction); // Must not be in transaction
    }

    /// Abort transaction (discard all buffered events)
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: tx_id matches current_tx_id
    ///   - Pre: in_transaction is true
    ///   - Post: all pending events discarded
    ///   - Post: in_transaction is false
    fn abort_transaction(self: *Simulator, tx_id: u64) !void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(tx_id > 0); // TX ID must be non-zero
        assert(self.in_transaction); // Must be in transaction

        if (tx_id != self.current_tx_id) {
            return error.TransactionIdMismatch;
        }

        // Discard all pending events
        self.in_transaction = false;
        self.current_tx_id = 0;
        self.pending_count = 0;

        assert(!self.in_transaction); // Must not be in transaction
    }

    /// Check if more events remain
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: returns true if current_event < event_count
    pub fn has_next(self: *const Simulator) bool {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(self.current_event <= self.event_count); // Current within bounds

        return self.current_event < self.event_count;
    }

    /// Reset simulator to beginning
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: current_event = 0
    ///   - Post: state reset to initial
    ///   - Post: registry cleared
    ///   - Post: no transaction in progress
    pub fn reset(self: *Simulator) void {
        assert(@intFromPtr(self) != 0); // Self must be valid

        self.current_event = 0;
        self.state = State.init();
        self.registry.clear();
        self.in_transaction = false;
        self.current_tx_id = 0;
        self.pending_count = 0;

        assert(self.current_event == 0); // Reset to start
        assert(self.state.services_started == 0); // State cleared
        assert(!self.in_transaction); // No transaction
    }
};

/// Decode WAL entry into simulation event
///
/// Invariants:
///   - Pre: entry is valid pointer
///   - Pre: entry CRC is valid
///   - Post: returned event matches entry type
fn decode_entry(entry: *const wal.Entry) !Event {
    assert(@intFromPtr(entry) != 0); // Entry must be valid
    assert(entry.verify_crc32()); // CRC must be valid

    const event_type: EventType = switch (entry.entry_type) {
        .service_start => .service_start,
        .service_stop => .service_stop,
        .proxy_accept => .proxy_accept,
        .proxy_close => .proxy_close,
        .config_reload => .config_reload,
        .checkpoint => .checkpoint,
        .tx_begin => .tx_begin,
        .tx_commit => .tx_commit,
        .tx_abort => .tx_abort,
    };

    const event_data: EventData = switch (entry.entry_type) {
        .service_start => blk: {
            const payload: *const wal.ServiceStartPayload = @ptrCast(@alignCast(&entry.payload));
            break :blk EventData{
                .service_start = ServiceStartData{
                    .service_id = payload.service_id,
                    .port = payload.port,
                },
            };
        },
        .service_stop => blk: {
            const payload: *const wal.ServiceStopPayload = @ptrCast(@alignCast(&entry.payload));
            break :blk EventData{
                .service_stop = ServiceStopData{
                    .service_id = payload.service_id,
                    .exit_code = payload.exit_code,
                },
            };
        },
        .proxy_accept => blk: {
            const payload: *const wal.ProxyAcceptPayload = @ptrCast(@alignCast(&entry.payload));
            break :blk EventData{
                .proxy_accept = ProxyAcceptData{
                    .connection_id = payload.connection_id,
                    .service_id = payload.service_id,
                    .client_port = payload.client_port,
                },
            };
        },
        .proxy_close => blk: {
            const payload: *const wal.ProxyClosePayload = @ptrCast(@alignCast(&entry.payload));
            break :blk EventData{
                .proxy_close = ProxyCloseData{
                    .connection_id = payload.connection_id,
                    .bytes_sent = payload.bytes_sent,
                    .bytes_received = payload.bytes_received,
                },
            };
        },
        .config_reload => EventData{ .config_reload = {} },
        .checkpoint => EventData{ .checkpoint = {} },
        .tx_begin => blk: {
            const payload: *const wal.TxBeginPayload = @ptrCast(@alignCast(&entry.payload));
            break :blk EventData{
                .tx_begin = TxBeginData{
                    .tx_id = payload.tx_id,
                    .event_count = payload.event_count,
                },
            };
        },
        .tx_commit => blk: {
            const payload: *const wal.TxCommitPayload = @ptrCast(@alignCast(&entry.payload));
            break :blk EventData{
                .tx_commit = TxCommitData{
                    .tx_id = payload.tx_id,
                    .event_count = payload.event_count,
                },
            };
        },
        .tx_abort => blk: {
            const payload: *const wal.TxAbortPayload = @ptrCast(@alignCast(&entry.payload));
            break :blk EventData{
                .tx_abort = TxAbortData{
                    .tx_id = payload.tx_id,
                    .reason_code = payload.reason_code,
                },
            };
        },
    };

    return Event{
        .timestamp_us = entry.timestamp_us,
        .event_type = event_type,
        .data = event_data,
    };
}
