//! Simple benchmark for SIMD optimizations in the Nix parser.
//!
//! This benchmark measures the performance impact of SIMD optimizations
//! on common tokenizer operations.

const std = @import("std");
const nix = @import("nix");

fn benchParse(allocator: std.mem.Allocator, source: []const u8, iterations: usize) !u64 {
    const start = std.time.nanoTimestamp();

    for (0..iterations) |_| {
        var cst = try nix.parse(allocator, source);
        cst.deinit();
    }

    const end = std.time.nanoTimestamp();
    return @intCast(end - start);
}

fn formatBytes(bytes: usize, buf: []u8) []const u8 {
    if (bytes < 1024) {
        return std.fmt.bufPrint(buf, "{} bytes", .{bytes}) catch unreachable;
    } else if (bytes < 1024 * 1024) {
        const kb = @as(f64, @floatFromInt(bytes)) / 1024.0;
        return std.fmt.bufPrint(buf, "{d:.1} KB", .{kb}) catch unreachable;
    } else {
        const mb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:.1} MB", .{mb}) catch unreachable;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("════════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("  Nix Parser SIMD Benchmark\n", .{});
    std.debug.print("════════════════════════════════════════════════════════════════\n\n", .{});

    // Benchmark 1: Whitespace-heavy input
    {
        var buf: [10240]u8 = undefined;
        @memset(&buf, ' ');
        buf[buf.len - 1] = '1';

        const iterations: usize = 1000;
        const ns = try benchParse(allocator, &buf, iterations);

        const ns_per_iter = ns / iterations;
        const bytes_per_sec = (@as(u64, buf.len) * iterations * 1_000_000_000) / ns;

        var size_buf: [64]u8 = undefined;
        const size_str = formatBytes(buf.len, &size_buf);

        std.debug.print("Whitespace scan ({s}):\n", .{size_str});
        std.debug.print("  Time:       {d:.2} μs/iter\n", .{@as(f64, @floatFromInt(ns_per_iter)) / 1000.0});
        std.debug.print("  Throughput: ", .{});

        var throughput_buf: [64]u8 = undefined;
        std.debug.print("{s}/s\n\n", .{formatBytes(bytes_per_sec, &throughput_buf)});
    }

    // Benchmark 2: Identifier-heavy input
    {
        var buf: [10240]u8 = undefined;
        for (&buf, 0..) |*ch, i| {
            ch.* = 'a' + @as(u8, @intCast(i % 26));
        }
        buf[buf.len - 1] = ' ';

        const iterations: usize = 1000;
        const ns = try benchParse(allocator, &buf, iterations);

        const ns_per_iter = ns / iterations;
        const bytes_per_sec = (@as(u64, buf.len) * iterations * 1_000_000_000) / ns;

        var size_buf: [64]u8 = undefined;
        const size_str = formatBytes(buf.len, &size_buf);

        std.debug.print("Identifier scan ({s}):\n", .{size_str});
        std.debug.print("  Time:       {d:.2} μs/iter\n", .{@as(f64, @floatFromInt(ns_per_iter)) / 1000.0});
        std.debug.print("  Throughput: ", .{});

        var throughput_buf: [64]u8 = undefined;
        std.debug.print("{s}/s\n\n", .{formatBytes(bytes_per_sec, &throughput_buf)});
    }

    // Benchmark 3: Number-heavy input
    {
        var buf: [10240]u8 = undefined;
        for (&buf, 0..) |*ch, i| {
            ch.* = '0' + @as(u8, @intCast(i % 10));
        }
        buf[buf.len - 1] = ' ';

        const iterations: usize = 1000;
        const ns = try benchParse(allocator, &buf, iterations);

        const ns_per_iter = ns / iterations;
        const bytes_per_sec = (@as(u64, buf.len) * iterations * 1_000_000_000) / ns;

        var size_buf: [64]u8 = undefined;
        const size_str = formatBytes(buf.len, &size_buf);

        std.debug.print("Number scan ({s}):\n", .{size_str});
        std.debug.print("  Time:       {d:.2} μs/iter\n", .{@as(f64, @floatFromInt(ns_per_iter)) / 1000.0});
        std.debug.print("  Throughput: ", .{});

        var throughput_buf: [64]u8 = undefined;
        std.debug.print("{s}/s\n\n", .{formatBytes(bytes_per_sec, &throughput_buf)});
    }

    // Benchmark 4: Real Nix file
    {
        const source =
            \\{
            \\  description = "A very nice package";
            \\
            \\  inputs = {
            \\    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
            \\    flake-utils.url = "github:numtide/flake-utils";
            \\  };
            \\
            \\  outputs = { self, nixpkgs, flake-utils }:
            \\    flake-utils.lib.eachDefaultSystem (system:
            \\      let
            \\        pkgs = import nixpkgs { inherit system; };
            \\      in {
            \\        packages.default = pkgs.hello;
            \\        devShells.default = pkgs.mkShell {
            \\          buildInputs = [ pkgs.hello ];
            \\        };
            \\      });
            \\}
        ;

        const iterations: usize = 10000;
        const ns = try benchParse(allocator, source, iterations);

        const ns_per_iter = ns / iterations;
        const bytes_per_sec = (@as(u64, source.len) * iterations * 1_000_000_000) / ns;

        var size_buf: [64]u8 = undefined;
        const size_str = formatBytes(source.len, &size_buf);

        std.debug.print("Real Nix flake ({s}):\n", .{size_str});
        std.debug.print("  Time:       {d:.2} μs/iter\n", .{@as(f64, @floatFromInt(ns_per_iter)) / 1000.0});
        std.debug.print("  Throughput: ", .{});

        var throughput_buf: [64]u8 = undefined;
        std.debug.print("{s}/s\n\n", .{formatBytes(bytes_per_sec, &throughput_buf)});
    }

    std.debug.print("════════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("  SIMD optimizations active on:\n", .{});
    std.debug.print("    - Whitespace scanning (spaces, tabs, newlines)\n", .{});
    std.debug.print("    - Identifier scanning (alphanumeric + _-')\n", .{});
    std.debug.print("    - Number scanning (digits)\n", .{});
    std.debug.print("════════════════════════════════════════════════════════════════\n\n", .{});
}
