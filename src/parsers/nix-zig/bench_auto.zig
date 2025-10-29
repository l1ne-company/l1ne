//! Automated benchmark suite with JSON export
//! Compatible with Criterion-style output for comparison

const std = @import("std");
const nix = @import("nix");

const BenchmarkResult = struct {
    name: []const u8,
    file_size_bytes: usize,
    iterations: usize,
    mean_ns: f64,
    stddev_ns: f64,
    min_ns: u64,
    max_ns: u64,
    mean_ms: f64,
    throughput_mbps: f64,
    throughput_mibps: f64,
};

fn calculateMean(times: []const u64) f64 {
    var sum: u64 = 0;
    for (times) |t| sum += t;
    return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(times.len));
}

fn calculateStdDev(times: []const u64, mean: f64) f64 {
    var sum_squared_diff: f64 = 0.0;
    for (times) |t| {
        const diff = @as(f64, @floatFromInt(t)) - mean;
        sum_squared_diff += diff * diff;
    }
    return @sqrt(sum_squared_diff / @as(f64, @floatFromInt(times.len)));
}

fn runBenchmark(
    allocator: std.mem.Allocator,
    name: []const u8,
    source: []const u8,
    iterations: usize,
) !BenchmarkResult {
    // Warmup
    for (0..10) |_| {
        var cst = try nix.parse(allocator, source);
        cst.deinit();
    }

    // Benchmark
    const times = try allocator.alloc(u64, iterations);
    defer allocator.free(times);

    for (times) |*time| {
        const start = std.time.nanoTimestamp();
        var cst = try nix.parse(allocator, source);
        cst.deinit();
        const end = std.time.nanoTimestamp();
        time.* = @intCast(end - start);
    }

    const mean_ns = calculateMean(times);
    const stddev_ns = calculateStdDev(times, mean_ns);

    var min_ns = times[0];
    var max_ns = times[0];
    for (times) |t| {
        if (t < min_ns) min_ns = t;
        if (t > max_ns) max_ns = t;
    }

    const mean_ms = mean_ns / 1_000_000.0;
    const throughput_bps = (@as(f64, @floatFromInt(source.len)) * 1_000_000_000.0) / mean_ns;
    const throughput_mbps = throughput_bps / (1000.0 * 1000.0); // MB/s (decimal)
    const throughput_mibps = throughput_bps / (1024.0 * 1024.0); // MiB/s (binary)

    return BenchmarkResult{
        .name = name,
        .file_size_bytes = source.len,
        .iterations = iterations,
        .mean_ns = mean_ns,
        .stddev_ns = stddev_ns,
        .min_ns = min_ns,
        .max_ns = max_ns,
        .mean_ms = mean_ms,
        .throughput_mbps = throughput_mbps,
        .throughput_mibps = throughput_mibps,
    };
}

fn printResult(result: BenchmarkResult) void {
    const min_ms = @as(f64, @floatFromInt(result.min_ns)) / 1_000_000.0;
    const max_ms = @as(f64, @floatFromInt(result.max_ns)) / 1_000_000.0;
    const stddev_ms = result.stddev_ns / 1_000_000.0;

    std.debug.print("\n{s}\n", .{result.name});
    std.debug.print("                        time:   [{d:.3} ms {d:.3} ms {d:.3} ms]\n", .{
        min_ms,
        result.mean_ms,
        max_ms,
    });
    std.debug.print("                        thrpt:  [{d:.3} MiB/s {d:.3} MiB/s {d:.3} MiB/s]\n", .{
        result.throughput_mibps,
        result.throughput_mibps,
        result.throughput_mibps,
    });
    std.debug.print("                        stddev: {d:.3} ms ({d:.1}%)\n", .{
        stddev_ms,
        (stddev_ms / result.mean_ms) * 100.0,
    });
}

fn exportJSON(allocator: std.mem.Allocator, results: []const BenchmarkResult, filename: []const u8) !void {
    _ = allocator;
    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();

    // Build JSON manually
    _ = try file.write("{\n");
    _ = try file.write("  \"framework\": \"zig-simd-parser\",\n");
    _ = try file.write("  \"benchmarks\": [\n");

    for (results, 0..) |result, i| {
        _ = try file.write("    {\n");

        var buf: [1024]u8 = undefined;
        var line = try std.fmt.bufPrint(&buf, "      \"name\": \"{s}\",\n", .{result.name});
        _ = try file.write(line);

        line = try std.fmt.bufPrint(&buf, "      \"file_size_bytes\": {d},\n", .{result.file_size_bytes});
        _ = try file.write(line);

        line = try std.fmt.bufPrint(&buf, "      \"iterations\": {d},\n", .{result.iterations});
        _ = try file.write(line);

        line = try std.fmt.bufPrint(&buf, "      \"mean_ns\": {d:.0},\n", .{result.mean_ns});
        _ = try file.write(line);

        line = try std.fmt.bufPrint(&buf, "      \"mean_ms\": {d:.3},\n", .{result.mean_ms});
        _ = try file.write(line);

        line = try std.fmt.bufPrint(&buf, "      \"stddev_ns\": {d:.0},\n", .{result.stddev_ns});
        _ = try file.write(line);

        line = try std.fmt.bufPrint(&buf, "      \"min_ns\": {d},\n", .{result.min_ns});
        _ = try file.write(line);

        line = try std.fmt.bufPrint(&buf, "      \"max_ns\": {d},\n", .{result.max_ns});
        _ = try file.write(line);

        line = try std.fmt.bufPrint(&buf, "      \"throughput_mbps\": {d:.3},\n", .{result.throughput_mbps});
        _ = try file.write(line);

        line = try std.fmt.bufPrint(&buf, "      \"throughput_mibps\": {d:.3}\n", .{result.throughput_mibps});
        _ = try file.write(line);

        if (i < results.len - 1) {
            _ = try file.write("    },\n");
        } else {
            _ = try file.write("    }\n");
        }
    }

    _ = try file.write("  ]\n");
    _ = try file.write("}\n");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const all_packages = @embedFile("test_data/bench/all-packages.nix");

    std.debug.print("Gnuplot not found, using builtin formatter\n", .{});
    std.debug.print("Benchmarking all-packages/all-packages: Collecting 30 samples\n", .{});

    const result = try runBenchmark(allocator, "all-packages/all-packages", all_packages, 30);

    printResult(result);

    // Export JSON
    const results = [_]BenchmarkResult{result};
    try exportJSON(allocator, &results, "benchmark_results.json");

    std.debug.print("\n", .{});
    std.debug.print("Results exported to: benchmark_results.json\n", .{});
}
