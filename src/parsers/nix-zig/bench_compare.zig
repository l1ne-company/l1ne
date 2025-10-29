//! Comparison benchmark against Rust rnix-parser.
//!
//! This benchmark uses the same 802KB all-packages.nix file that
//! the Rust rnix-parser uses in its Criterion benchmarks.
//!
//! Methodology matches Criterion:
//! - 30 sample iterations
//! - Warmup phase
//! - Statistical analysis (mean, stddev)
//! - Throughput measurement

const std = @import("std");
const nix = @import("nix");

const all_packages = @embedFile("test_data/bench/all-packages.nix");

fn calculateMean(times: []const u64) f64 {
    var sum: u64 = 0;
    for (times) |t| {
        sum += t;
    }
    return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(times.len));
}

fn calculateStdDev(times: []const u64, mean: f64) f64 {
    var sum_squared_diff: f64 = 0.0;
    for (times) |t| {
        const diff = @as(f64, @floatFromInt(t)) - mean;
        sum_squared_diff += diff * diff;
    }
    const variance = sum_squared_diff / @as(f64, @floatFromInt(times.len));
    return @sqrt(variance);
}

fn calculateMin(times: []const u64) u64 {
    var min_val = times[0];
    for (times) |t| {
        if (t < min_val) min_val = t;
    }
    return min_val;
}

fn calculateMax(times: []const u64) u64 {
    var max_val = times[0];
    for (times) |t| {
        if (t > max_val) max_val = t;
    }
    return max_val;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("════════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("  Zig SIMD Parser vs Rust rnix-parser Comparison\n", .{});
    std.debug.print("════════════════════════════════════════════════════════════════\n\n", .{});

    std.debug.print("Benchmark file: all-packages.nix\n", .{});
    std.debug.print("File size:      {d:.2} KB ({d} bytes)\n", .{
        @as(f64, @floatFromInt(all_packages.len)) / 1024.0,
        all_packages.len,
    });
    std.debug.print("Sample size:    30 (matching Criterion)\n\n", .{});

    // Warmup phase (10 iterations)
    std.debug.print("Warming up...\n", .{});
    for (0..10) |_| {
        var cst = try nix.parse(allocator, all_packages);
        cst.deinit();
    }

    std.debug.print("Running benchmark...\n\n", .{});

    // Benchmark phase (30 samples)
    const iterations: usize = 30;
    var times: [iterations]u64 = undefined;

    for (&times) |*time| {
        const start = std.time.nanoTimestamp();
        var cst = try nix.parse(allocator, all_packages);
        cst.deinit();
        const end = std.time.nanoTimestamp();
        time.* = @intCast(end - start);
    }

    // Calculate statistics
    const mean_ns = calculateMean(&times);
    const stddev_ns = calculateStdDev(&times, mean_ns);
    const min_ns = calculateMin(&times);
    const max_ns = calculateMax(&times);

    const mean_ms = mean_ns / 1_000_000.0;
    const stddev_ms = stddev_ns / 1_000_000.0;
    const min_ms = @as(f64, @floatFromInt(min_ns)) / 1_000_000.0;
    const max_ms = @as(f64, @floatFromInt(max_ns)) / 1_000_000.0;

    // Calculate throughput (bytes per second)
    const throughput_bps = (@as(f64, @floatFromInt(all_packages.len)) * 1_000_000_000.0) / mean_ns;
    const throughput_mbps = throughput_bps / (1024.0 * 1024.0);

    // Print results in Criterion-style format
    std.debug.print("────────────────────────────────────────────────────────────────\n", .{});
    std.debug.print("  Zig SIMD Parser Results\n", .{});
    std.debug.print("────────────────────────────────────────────────────────────────\n\n", .{});

    std.debug.print("Time:       [{d:.2} ms {d:.2} ms {d:.2} ms]\n", .{ min_ms, mean_ms, max_ms });
    std.debug.print("            (min)    (mean)   (max)\n\n", .{});

    std.debug.print("Std dev:    {d:.2} ms ({d:.1}%)\n", .{
        stddev_ms,
        (stddev_ms / mean_ms) * 100.0,
    });
    std.debug.print("Throughput: {d:.1} MB/s\n\n", .{throughput_mbps});

    // Per-iteration breakdown
    std.debug.print("Per-iteration time: {d:.3} ms/iter\n", .{mean_ms});
    std.debug.print("Parses per second:  {d:.1}\n\n", .{1000.0 / mean_ms});

    std.debug.print("────────────────────────────────────────────────────────────────\n", .{});
    std.debug.print("  To compare with Rust rnix-parser:\n", .{});
    std.debug.print("────────────────────────────────────────────────────────────────\n\n", .{});
    std.debug.print("  cd /home/toga/code/l1ne-company/rnix-parser\n", .{});
    std.debug.print("  nix develop -c cargo bench --bench all-packages\n\n", .{});
    std.debug.print("════════════════════════════════════════════════════════════════\n\n", .{});
}
