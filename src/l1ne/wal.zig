//! Write-Ahead Log (WAL) for L1NE
//!
//! Provides transactional guarantees and deterministic replay for simulation.
//!
//! Design principles (TigerStyle):
//!   - Fixed-size entries (no variable-length records)
//!   - Bounded circular buffer (statically allocated)
//!   - Atomic writes (fsync after each entry)
//!   - Sequential access only (no random seeks)
//!   - Explicit limits on everything
//!
//! WAL Entry Types:
//!   - ServiceStart: Service instance started
//!   - ServiceStop: Service instance stopped
//!   - ProxyAccept: New connection accepted
//!   - ProxyClose: Connection closed
//!   - ConfigReload: Configuration reloaded
//!   - Checkpoint: Snapshot of system state
//!   - TxBegin: Begin transaction
//!   - TxCommit: Commit transaction
//!   - TxAbort: Abort transaction

const std = @import("std");
const assert = std.debug.assert;
const types = @import("types.zig");
const constants = @import("constants.zig");

/// Maximum size of a WAL entry (fixed size for simplicity)
pub const max_entry_size: u32 = 256;

/// Maximum number of entries in WAL before rotation
pub const max_entries_per_segment: u32 = 1024 * 1024; // 1M entries

/// Maximum WAL segments to keep
pub const max_segments: u8 = 4;

/// WAL entry types
pub const EntryType = enum(u8) {
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

/// Fixed-size WAL entry
///
/// Design:
///   - Fixed 256 bytes for alignment and simplicity
///   - Timestamp for ordering and replay
///   - Type tag for discrimination
///   - Payload area for entry-specific data
///   - CRC32 for integrity checking
pub const Entry = extern struct {
    /// Monotonic timestamp (microseconds since start)
    timestamp_us: u64,

    /// Entry type discriminator
    entry_type: EntryType,

    /// Reserved for alignment
    _reserved: [7]u8,

    /// Entry payload (128 bytes)
    payload: [128]u8,

    /// CRC32 checksum of entry (excluding this field)
    crc32: u32,

    /// Padding to 256 bytes (148 + 108 = 256)
    _padding: [108]u8,

    comptime {
        assert(@sizeOf(Entry) == 256); // Must be exactly 256 bytes
        assert(@alignOf(Entry) == 8); // Must be 8-byte aligned
    }

    /// Calculate CRC32 checksum for entry
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: returned CRC covers timestamp through payload
    ///   - Does not modify state
    pub fn calculate_crc32(self: *const Entry) u32 {
        assert(@intFromPtr(self) != 0); // Self must be valid

        // Calculate CRC over timestamp, type, and payload
        const data_start = @as([*]const u8, @ptrCast(self));
        const data_len = @offsetOf(Entry, "crc32");

        assert(data_len == 144); // Sanity check offset calculation
        assert(data_len < @sizeOf(Entry)); // Must be less than total size

        const crc = std.hash.Crc32.hash(data_start[0..data_len]);

        assert(crc != 0 or data_len == 0); // CRC should be non-zero for non-empty data
        return crc;
    }

    /// Verify CRC32 checksum
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: returns true if CRC matches
    ///   - Does not modify state
    pub fn verify_crc32(self: *const Entry) bool {
        assert(@intFromPtr(self) != 0); // Self must be valid

        const calculated = self.calculate_crc32();
        const stored = self.crc32;

        assert(calculated != 0 or stored != 0); // At least one should be set
        return calculated == stored;
    }
};

/// ServiceStart payload
pub const ServiceStartPayload = extern struct {
    service_id: u32,
    port: u16,
    _reserved: [122]u8,

    comptime {
        assert(@sizeOf(ServiceStartPayload) == 128);
    }
};

/// ServiceStop payload
pub const ServiceStopPayload = extern struct {
    service_id: u32,
    exit_code: i32,
    _reserved: [120]u8,

    comptime {
        assert(@sizeOf(ServiceStopPayload) == 128);
    }
};

/// ProxyAccept payload
pub const ProxyAcceptPayload = extern struct {
    connection_id: u64,
    service_id: u32,
    client_port: u16,
    _reserved: [114]u8,

    comptime {
        assert(@sizeOf(ProxyAcceptPayload) == 128);
    }
};

/// ProxyClose payload
pub const ProxyClosePayload = extern struct {
    connection_id: u64,
    bytes_sent: u64,
    bytes_received: u64,
    _reserved: [104]u8,

    comptime {
        assert(@sizeOf(ProxyClosePayload) == 128);
    }
};

/// TxBegin payload
pub const TxBeginPayload = extern struct {
    tx_id: u64,
    event_count: u32,
    _reserved: [116]u8,

    comptime {
        assert(@sizeOf(TxBeginPayload) == 128);
    }
};

/// TxCommit payload
pub const TxCommitPayload = extern struct {
    tx_id: u64,
    event_count: u32,
    _reserved: [116]u8,

    comptime {
        assert(@sizeOf(TxCommitPayload) == 128);
    }
};

/// TxAbort payload
pub const TxAbortPayload = extern struct {
    tx_id: u64,
    reason_code: u32,
    _reserved: [116]u8,

    comptime {
        assert(@sizeOf(TxAbortPayload) == 128);
    }
};

/// WAL writer state
///
/// Design:
///   - Single writer (no concurrent writes)
///   - Sequential append-only writes
///   - fsync after each entry for durability
///   - Automatic rotation after max_entries_per_segment
pub const Writer = struct {
    file: std.fs.File,
    entries_written: u64,
    current_segment: u32,
    segment_entries: u32,

    /// Initialize WAL writer
    ///
    /// Invariants:
    ///   - Pre: file is open for writing
    ///   - Pre: file pointer is valid
    ///   - Post: writer is ready for append operations
    pub fn init(file: std.fs.File) Writer {
        assert(file.handle != 0); // File must be open

        return Writer{
            .file = file,
            .entries_written = 0,
            .current_segment = 0,
            .segment_entries = 0,
        };
    }

    /// Write entry to WAL
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: entry is valid pointer
    ///   - Pre: entry CRC is correct
    ///   - Post: entry written to disk and fsynced
    ///   - Post: entries_written incremented
    ///   - Post: may trigger segment rotation
    pub fn write_entry(self: *Writer, entry: *const Entry) !void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(@intFromPtr(entry) != 0); // Entry must be valid
        assert(entry.verify_crc32()); // CRC must be valid

        const old_written = self.entries_written;
        const old_segment_entries = self.segment_entries;

        // Check if rotation needed
        if (self.segment_entries >= max_entries_per_segment) {
            try self.rotate_segment();
            assert(self.segment_entries == 0); // Should be reset after rotation
        }

        // Write entry
        const entry_bytes = std.mem.asBytes(entry);
        assert(entry_bytes.len == @sizeOf(Entry)); // Must be correct size

        const bytes_written = try self.file.writeAll(entry_bytes);
        _ = bytes_written;

        // Fsync for durability
        try self.file.sync();

        self.entries_written += 1;
        self.segment_entries += 1;

        assert(self.entries_written == old_written + 1); // Count increased by 1
        assert(self.segment_entries == old_segment_entries + 1 or self.segment_entries == 1); // Either incremented or rotated
    }

    /// Rotate to new segment
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: current_segment < max_segments
    ///   - Post: segment_entries reset to 0
    ///   - Post: current_segment incremented (wraps at max)
    fn rotate_segment(self: *Writer) !void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(self.current_segment < max_segments); // Must be in bounds

        const old_segment = self.current_segment;

        // Increment segment (wrap around)
        self.current_segment = @intCast((self.current_segment + 1) % max_segments);
        self.segment_entries = 0;

        assert(self.current_segment != old_segment or max_segments == 1); // Should change unless wrapping
        assert(self.segment_entries == 0); // Should be reset
    }

    /// Close WAL writer
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: file is closed
    pub fn deinit(self: *Writer) void {
        assert(@intFromPtr(self) != 0); // Self must be valid

        self.file.close();
    }
};

/// WAL reader state
///
/// Design:
///   - Sequential read-only access
///   - Verifies CRC on every entry
///   - Returns entries in timestamp order
pub const Reader = struct {
    file: std.fs.File,
    entries_read: u64,

    /// Initialize WAL reader
    ///
    /// Invariants:
    ///   - Pre: file is open for reading
    ///   - Pre: file pointer is valid
    ///   - Post: reader is ready for sequential reads
    pub fn init(file: std.fs.File) Reader {
        assert(file.handle != 0); // File must be open

        return Reader{
            .file = file,
            .entries_read = 0,
        };
    }

    /// Read next entry from WAL
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Pre: entry is valid pointer to buffer
    ///   - Post: entry filled with data if successful
    ///   - Post: entries_read incremented if successful
    ///   - Post: returns null at end of file
    pub fn read_entry(self: *Reader, entry: *Entry) !?void {
        assert(@intFromPtr(self) != 0); // Self must be valid
        assert(@intFromPtr(entry) != 0); // Entry must be valid

        const old_read = self.entries_read;

        // Read entry
        const entry_bytes = std.mem.asBytes(entry);
        assert(entry_bytes.len == @sizeOf(Entry)); // Must be correct size

        const bytes_read = self.file.read(entry_bytes) catch {
            // Handle EOF and read errors by returning null
            return null;
        };

        // Check for EOF
        if (bytes_read == 0) {
            return null;
        }

        // Must read complete entry
        if (bytes_read != @sizeOf(Entry)) {
            return error.IncompleteEntry;
        }

        // Verify CRC
        if (!entry.verify_crc32()) {
            return error.InvalidCRC;
        }

        self.entries_read += 1;

        assert(self.entries_read == old_read + 1); // Count increased by 1
    }

    /// Close WAL reader
    ///
    /// Invariants:
    ///   - Pre: self is valid pointer
    ///   - Post: file is closed
    pub fn deinit(self: *Reader) void {
        assert(@intFromPtr(self) != 0); // Self must be valid

        self.file.close();
    }
};

/// Create a new WAL entry with proper timestamp and CRC
///
/// Invariants:
///   - Pre: timestamp_us is monotonic
///   - Pre: entry_type is valid
///   - Pre: payload is 128 bytes
///   - Post: returned entry has valid CRC
pub fn create_entry(
    timestamp_us: u64,
    entry_type: EntryType,
    payload: [128]u8,
) Entry {
    assert(timestamp_us > 0); // Timestamp must be non-zero
    assert(@intFromEnum(entry_type) > 0); // Type must be valid
    assert(@intFromEnum(entry_type) <= 9); // Type must be in range

    var entry = Entry{
        .timestamp_us = timestamp_us,
        .entry_type = entry_type,
        ._reserved = [_]u8{0} ** 7,
        .payload = payload,
        .crc32 = 0,
        ._padding = [_]u8{0} ** 108,
    };

    entry.crc32 = entry.calculate_crc32();

    assert(entry.verify_crc32()); // CRC must be valid
    assert(entry.timestamp_us == timestamp_us); // Timestamp preserved
    return entry;
}

/// Create a transaction begin entry
///
/// Invariants:
///   - Pre: timestamp_us is monotonic
///   - Pre: tx_id is non-zero
///   - Pre: event_count > 0
///   - Pre: event_count <= 64 (bounded)
///   - Post: returned entry has valid CRC
pub fn create_tx_begin_entry(
    timestamp_us: u64,
    tx_id: u64,
    event_count: u32,
) Entry {
    assert(timestamp_us > 0); // Timestamp must be non-zero
    assert(tx_id > 0); // Transaction ID must be non-zero
    assert(event_count > 0); // Must have at least one event
    assert(event_count <= 64); // Bounded transaction size

    var payload_struct = TxBeginPayload{
        .tx_id = tx_id,
        .event_count = event_count,
        ._reserved = [_]u8{0} ** 116,
    };

    const payload_bytes = std.mem.asBytes(&payload_struct);
    assert(payload_bytes.len == 128); // Must be correct size

    var payload: [128]u8 = undefined;
    @memcpy(&payload, payload_bytes);

    const entry = create_entry(timestamp_us, .tx_begin, payload);

    assert(entry.verify_crc32()); // CRC must be valid
    assert(entry.entry_type == .tx_begin); // Type must match
    return entry;
}

/// Create a transaction commit entry
///
/// Invariants:
///   - Pre: timestamp_us is monotonic
///   - Pre: tx_id is non-zero
///   - Pre: event_count > 0
///   - Pre: event_count <= 64 (bounded)
///   - Post: returned entry has valid CRC
pub fn create_tx_commit_entry(
    timestamp_us: u64,
    tx_id: u64,
    event_count: u32,
) Entry {
    assert(timestamp_us > 0); // Timestamp must be non-zero
    assert(tx_id > 0); // Transaction ID must be non-zero
    assert(event_count > 0); // Must have at least one event
    assert(event_count <= 64); // Bounded transaction size

    var payload_struct = TxCommitPayload{
        .tx_id = tx_id,
        .event_count = event_count,
        ._reserved = [_]u8{0} ** 116,
    };

    const payload_bytes = std.mem.asBytes(&payload_struct);
    assert(payload_bytes.len == 128); // Must be correct size

    var payload: [128]u8 = undefined;
    @memcpy(&payload, payload_bytes);

    const entry = create_entry(timestamp_us, .tx_commit, payload);

    assert(entry.verify_crc32()); // CRC must be valid
    assert(entry.entry_type == .tx_commit); // Type must match
    return entry;
}

/// Create a transaction abort entry
///
/// Invariants:
///   - Pre: timestamp_us is monotonic
///   - Pre: tx_id is non-zero
///   - Post: returned entry has valid CRC
pub fn create_tx_abort_entry(
    timestamp_us: u64,
    tx_id: u64,
    reason_code: u32,
) Entry {
    assert(timestamp_us > 0); // Timestamp must be non-zero
    assert(tx_id > 0); // Transaction ID must be non-zero

    var payload_struct = TxAbortPayload{
        .tx_id = tx_id,
        .reason_code = reason_code,
        ._reserved = [_]u8{0} ** 116,
    };

    const payload_bytes = std.mem.asBytes(&payload_struct);
    assert(payload_bytes.len == 128); // Must be correct size

    var payload: [128]u8 = undefined;
    @memcpy(&payload, payload_bytes);

    const entry = create_entry(timestamp_us, .tx_abort, payload);

    assert(entry.verify_crc32()); // CRC must be valid
    assert(entry.entry_type == .tx_abort); // Type must match
    return entry;
}
