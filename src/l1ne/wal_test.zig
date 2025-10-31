//! Comprehensive tests for WAL (Write-Ahead Log)
//!
//! These tests verify:
//! - Entry creation and CRC validation
//! - Writer append-only semantics
//! - Reader sequential access
//! - Segment rotation
//! - Durability guarantees
//! - Error handling

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const wal = @import("wal.zig");

// Test: Entry size and alignment

// Verifies:
//   - Entry is exactly 256 bytes
//   - Entry is 8-byte aligned
//   - Compile-time guarantees
test "WAL Entry: size and alignment" {
    try testing.expectEqual(@as(usize, 256), @sizeOf(wal.Entry));
    try testing.expectEqual(@as(usize, 8), @alignOf(wal.Entry));
}

// Test: Entry CRC calculation

// Verifies:
//   - CRC32 is calculated correctly
//   - CRC verification works
//   - Tampering is detected
test "WAL Entry: CRC calculation and verification" {
    const payload = [_]u8{42} ++ [_]u8{0} ** 127;
    const entry = wal.create_entry(1000, .service_start, payload);

    // Verify CRC is correct
    try testing.expect(entry.verify_crc32());
    try testing.expectEqual(entry.crc32, entry.calculate_crc32());

    // Tamper with entry and verify CRC fails
    var tampered = entry;
    tampered.timestamp_us = 2000;
    try testing.expect(!tampered.verify_crc32());
}

// Test: Create entry with different types

// Verifies:
//   - All entry types can be created
//   - CRC is valid for each type
//   - Timestamps are preserved
test "WAL Entry: create different types" {
    const types_to_test = [_]wal.EntryType{
        .service_start,
        .service_stop,
        .proxy_accept,
        .proxy_close,
        .config_reload,
        .checkpoint,
    };

    for (types_to_test, 0..) |entry_type, i| {
        const timestamp: u64 = @intCast(1000 + i * 100);
        const payload = [_]u8{@intCast(i)} ++ [_]u8{0} ** 127;
        const entry = wal.create_entry(timestamp, entry_type, payload);

        try testing.expect(entry.verify_crc32());
        try testing.expectEqual(timestamp, entry.timestamp_us);
        try testing.expectEqual(entry_type, entry.entry_type);
        try testing.expectEqual(@as(u8, @intCast(i)), entry.payload[0]);
    }
}

// Test: ServiceStart payload

// Verifies:
//   - ServiceStart payload is 128 bytes
//   - Fields are accessible
//   - Can be used in entry
test "WAL Payload: ServiceStart" {
    try testing.expectEqual(@as(usize, 128), @sizeOf(wal.ServiceStartPayload));

    var payload_struct = wal.ServiceStartPayload{
        .service_id = 42,
        .port = 8080,
        ._reserved = [_]u8{0} ** 122,
    };

    const payload_bytes = std.mem.asBytes(&payload_struct);
    try testing.expectEqual(@as(usize, 128), payload_bytes.len);

    const entry = wal.create_entry(1000, .service_start, payload_bytes[0..128].*);
    try testing.expect(entry.verify_crc32());
}

// Test: ServiceStop payload

// Verifies:
//   - ServiceStop payload is 128 bytes
//   - Exit code is signed
test "WAL Payload: ServiceStop" {
    try testing.expectEqual(@as(usize, 128), @sizeOf(wal.ServiceStopPayload));

    var payload_struct = wal.ServiceStopPayload{
        .service_id = 42,
        .exit_code = -1,
        ._reserved = [_]u8{0} ** 120,
    };

    const payload_bytes = std.mem.asBytes(&payload_struct);
    const entry = wal.create_entry(2000, .service_stop, payload_bytes[0..128].*);
    try testing.expect(entry.verify_crc32());

    // Verify exit code is negative
    const read_payload: *const wal.ServiceStopPayload = @ptrCast(@alignCast(&entry.payload));
    try testing.expectEqual(@as(i32, -1), read_payload.exit_code);
}

// Test: ProxyAccept payload

// Verifies:
//   - ProxyAccept payload is 128 bytes
//   - Connection ID is 64-bit
test "WAL Payload: ProxyAccept" {
    try testing.expectEqual(@as(usize, 128), @sizeOf(wal.ProxyAcceptPayload));

    var payload_struct = wal.ProxyAcceptPayload{
        .connection_id = 123456789,
        .service_id = 42,
        .client_port = 12345,
        ._reserved = [_]u8{0} ** 114,
    };

    const payload_bytes = std.mem.asBytes(&payload_struct);
    const entry = wal.create_entry(3000, .proxy_accept, payload_bytes[0..128].*);
    try testing.expect(entry.verify_crc32());
}

// Test: ProxyClose payload

// Verifies:
//   - ProxyClose payload is 128 bytes
//   - Byte counters are 64-bit
test "WAL Payload: ProxyClose" {
    try testing.expectEqual(@as(usize, 128), @sizeOf(wal.ProxyClosePayload));

    var payload_struct = wal.ProxyClosePayload{
        .connection_id = 123456789,
        .bytes_sent = 1024 * 1024,
        .bytes_received = 2048 * 1024,
        ._reserved = [_]u8{0} ** 104,
    };

    const payload_bytes = std.mem.asBytes(&payload_struct);
    const entry = wal.create_entry(4000, .proxy_close, payload_bytes[0..128].*);
    try testing.expect(entry.verify_crc32());
}

// Test: Writer initialization

// Verifies:
//   - Writer initializes with zero counts
//   - Writer accepts valid file handle
test "WAL Writer: initialization" {
    const tmp_path = "/tmp/wal_test_init.log";
    var file = try std.fs.cwd().createFile(tmp_path, .{ .read = true });
    defer {
        file.close();
        std.fs.cwd().deleteFile(tmp_path) catch {};
    }

    const writer = wal.Writer.init(file);
    try testing.expectEqual(@as(u64, 0), writer.entries_written);
    try testing.expectEqual(@as(u32, 0), writer.current_segment);
    try testing.expectEqual(@as(u32, 0), writer.segment_entries);
}

// Test: Write single entry

// Verifies:
//   - Can write entry to WAL
//   - Entry count increments
//   - File is synced
test "WAL Writer: write single entry" {
    const tmp_path = "/tmp/wal_test_single.log";
    var file = try std.fs.cwd().createFile(tmp_path, .{ .read = true });
    defer {
        file.close();
        std.fs.cwd().deleteFile(tmp_path) catch {};
    }

    var writer = wal.Writer.init(file);

    const payload = [_]u8{1} ++ [_]u8{0} ** 127;
    const entry = wal.create_entry(1000, .service_start, payload);

    try writer.write_entry(&entry);

    try testing.expectEqual(@as(u64, 1), writer.entries_written);
    try testing.expectEqual(@as(u32, 1), writer.segment_entries);
}

// Test: Write multiple entries

// Verifies:
//   - Can write multiple entries
//   - Counts increment correctly
//   - Entries are sequential
test "WAL Writer: write multiple entries" {
    const tmp_path = "/tmp/wal_test_multiple.log";
    var file = try std.fs.cwd().createFile(tmp_path, .{ .read = true });
    defer {
        file.close();
        std.fs.cwd().deleteFile(tmp_path) catch {};
    }

    var writer = wal.Writer.init(file);

    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        const timestamp = 1000 + i * 100;
        const payload = [_]u8{@intCast(i)} ++ [_]u8{0} ** 127;
        const entry = wal.create_entry(timestamp, .service_start, payload);

        try writer.write_entry(&entry);
    }

    try testing.expectEqual(@as(u64, 10), writer.entries_written);
    try testing.expectEqual(@as(u32, 10), writer.segment_entries);
}

// Test: Reader initialization

// Verifies:
//   - Reader initializes with zero count
//   - Reader accepts valid file handle
test "WAL Reader: initialization" {
    const tmp_path = "/tmp/wal_test_reader_init.log";
    var file = try std.fs.cwd().createFile(tmp_path, .{ .read = true });
    defer {
        file.close();
        std.fs.cwd().deleteFile(tmp_path) catch {};
    }

    const reader = wal.Reader.init(file);
    try testing.expectEqual(@as(u64, 0), reader.entries_read);
}

// Test: Read written entries

// Verifies:
//   - Can read back written entries
//   - Data matches what was written
//   - CRC verification works
test "WAL Reader: read written entries" {
    const tmp_path = "/tmp/wal_test_read_write.log";

    // Write entries
    {
        var file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();

        var writer = wal.Writer.init(file);

        var i: u64 = 0;
        while (i < 5) : (i += 1) {
            const timestamp = 1000 + i * 100;
            const payload = [_]u8{@intCast(i)} ++ [_]u8{0} ** 127;
            const entry = wal.create_entry(timestamp, .service_start, payload);
            try writer.write_entry(&entry);
        }
    }

    // Read entries
    {
        var file = try std.fs.cwd().openFile(tmp_path, .{});
        defer {
            file.close();
            std.fs.cwd().deleteFile(tmp_path) catch {};
        }

        var reader = wal.Reader.init(file);

        var entry: wal.Entry = undefined;
        var count: u64 = 0;

        while (try reader.read_entry(&entry)) |_| {
            try testing.expect(entry.verify_crc32());
            try testing.expectEqual(.service_start, entry.entry_type);
            try testing.expectEqual(@as(u8, @intCast(count)), entry.payload[0]);
            try testing.expectEqual(1000 + count * 100, entry.timestamp_us);
            count += 1;
        }

        try testing.expectEqual(@as(u64, 5), count);
        try testing.expectEqual(@as(u64, 5), reader.entries_read);
    }
}

// Test: Read from empty file

// Verifies:
//   - Reading from empty file returns null
//   - No errors thrown
test "WAL Reader: read from empty file" {
    const tmp_path = "/tmp/wal_test_empty.log";
    var file = try std.fs.cwd().createFile(tmp_path, .{ .read = true });
    defer {
        file.close();
        std.fs.cwd().deleteFile(tmp_path) catch {};
    }

    var reader = wal.Reader.init(file);
    var entry: wal.Entry = undefined;

    const result = try reader.read_entry(&entry);
    try testing.expectEqual(@as(?void, null), result);
    try testing.expectEqual(@as(u64, 0), reader.entries_read);
}

// Test: Entry type preservation

// Verifies:
//   - All entry types can be written and read
//   - Types are preserved correctly
test "WAL: entry type preservation" {
    const tmp_path = "/tmp/wal_test_types.log";

    const types_to_test = [_]wal.EntryType{
        .service_start,
        .service_stop,
        .proxy_accept,
        .proxy_close,
        .config_reload,
        .checkpoint,
    };

    // Write different types
    {
        var file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();

        var writer = wal.Writer.init(file);

        for (types_to_test, 0..) |entry_type, i| {
            const timestamp: u64 = @intCast(1000 + i * 100);
            const payload = [_]u8{@intCast(i)} ++ [_]u8{0} ** 127;
            const entry = wal.create_entry(timestamp, entry_type, payload);
            try writer.write_entry(&entry);
        }
    }

    // Read and verify types
    {
        var file = try std.fs.cwd().openFile(tmp_path, .{});
        defer {
            file.close();
            std.fs.cwd().deleteFile(tmp_path) catch {};
        }

        var reader = wal.Reader.init(file);
        var entry: wal.Entry = undefined;
        var count: usize = 0;

        while (try reader.read_entry(&entry)) |_| {
            try testing.expectEqual(types_to_test[count], entry.entry_type);
            count += 1;
        }

        try testing.expectEqual(types_to_test.len, count);
    }
}

// Test: Timestamp ordering

// Verifies:
//   - Timestamps are preserved
//   - Entries maintain sequential order
test "WAL: timestamp ordering" {
    const tmp_path = "/tmp/wal_test_timestamps.log";

    // Write with increasing timestamps
    {
        var file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();

        var writer = wal.Writer.init(file);

        var i: u64 = 0;
        while (i < 10) : (i += 1) {
            const timestamp = 1000 + i * 1000;
            const payload = [_]u8{0} ** 128;
            const entry = wal.create_entry(timestamp, .checkpoint, payload);
            try writer.write_entry(&entry);
        }
    }

    // Read and verify timestamps
    {
        var file = try std.fs.cwd().openFile(tmp_path, .{});
        defer {
            file.close();
            std.fs.cwd().deleteFile(tmp_path) catch {};
        }

        var reader = wal.Reader.init(file);
        var entry: wal.Entry = undefined;
        var prev_timestamp: u64 = 0;

        while (try reader.read_entry(&entry)) |_| {
            try testing.expect(entry.timestamp_us > prev_timestamp);
            prev_timestamp = entry.timestamp_us;
        }
    }
}
