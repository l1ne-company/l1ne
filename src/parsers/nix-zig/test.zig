// Test data derived from rnix-parser:
// MIT License - Copyright (c) 2018 jD91mZM2
// https://github.com/nix-community/rnix-parser
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

const std = @import("std");
const nix = @import("root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <test.nix>\n", .{args[0]});
        std.debug.print("  Will compare output against test.expect\n", .{});
        return;
    }

    const nix_path = args[1];

    // Read the .nix file
    const nix_file = try std.fs.cwd().openFile(nix_path, .{});
    defer nix_file.close();

    const nix_source = try nix_file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(nix_source);

    // Parse it
    var cst = try nix.parse(allocator, nix_source);
    defer cst.deinit();

    // Print the CST
    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);

    try cst.printTree(output.writer(allocator));

    // Try to read .expect file
    const expect_path = try std.fmt.allocPrint(allocator, "{s}.expect", .{nix_path[0 .. nix_path.len - 4]});
    defer allocator.free(expect_path);

    if (std.fs.cwd().openFile(expect_path, .{})) |expect_file| {
        defer expect_file.close();

        const expected = try expect_file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(expected);

        // Compare
        if (std.mem.eql(u8, output.items, expected)) {
            std.debug.print("✓ PASS: {s}\n", .{nix_path});
        } else {
            std.debug.print("✗ FAIL: {s}\n", .{nix_path});
            std.debug.print("\nExpected:\n{s}\n", .{expected});
            std.debug.print("Got:\n{s}\n", .{output.items});
            return error.TestFailed;
        }
    } else |_| {
        // No .expect file, just print the output for inspection
        std.debug.print("Output for {s}:\n{s}\n", .{ nix_path, output.items });
    }
}
