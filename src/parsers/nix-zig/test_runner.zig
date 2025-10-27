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
const nix = @import("nix");

const TestResult = struct {
    name: []const u8,
    passed: bool,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_files = [_][]const u8{
        "apply.nix",
        "assert.nix",
        "attrpath_ident.nix",
        "attrset.nix",
        "attrset_dynamic.nix",
        "attrset_empty.nix",
        "attrset_rec.nix",
        "bool_arith_ops.nix",
        "bool_ops.nix",
        "bool_ops_eq.nix",
        "docs.nix",
        "has_attr_prec.nix",
        "if_elseif_else.nix",
        "import_nixpkgs.nix",
        "inherit.nix",
        "inherit_dynamic.nix",
        "interpolation.nix",
        "lambda_is_not_uri.nix",
        "lambda_list.nix",
        "lambda_nested.nix",
        "let.nix",
        "let_legacy.nix",
        "list.nix",
        "list_concat.nix",
        "math.nix",
        "math2.nix",
        "math_no_ws.nix",
        "merge.nix",
        "multiple.nix",
        "operators_right_assoc.nix",
        "or-as-ident.nix",
        "or_in_attr.nix",
        "path.nix",
        "path_interp.nix",
        "path_interp_no_prefix.nix",
        "path_no_newline.nix",
        "pattern_bind_left.nix",
        "pattern_bind_right.nix",
        "pattern_default.nix",
        "pattern_default_attrset.nix",
        "pattern_default_ellipsis.nix",
        "pattern_ellipsis.nix",
        "pattern_trailing_comma.nix",
        "pipe_left.nix",
        "pipe_left_assoc.nix",
        "pipe_left_math.nix",
        "pipe_mixed.nix",
        "pipe_mixed_math.nix",
        "pipe_right.nix",
        "pipe_right_assoc.nix",
        "pipe_right_math.nix",
        "select_default.nix",
        "select_ident.nix",
        "select_string_dynamic.nix",
        "string.nix",
        "string_complex_url.nix",
        "string_interp_ident.nix",
        "string_interp_nested.nix",
        "string_interp_select.nix",
        "trivia.nix",
        "with.nix",
        "with-import-let-in.nix",
    };

    var results = std.ArrayList(TestResult){};
    defer results.deinit(allocator);

    const test_dir = "src/parsers/nix-zig/test_data/parser/success";

    const sep = "────────────────────────────────────────────────────────────";

    std.debug.print("\nRunning Nix parser tests...\n", .{});
    std.debug.print("{s}\n", .{sep});

    for (test_files) |test_file| {
        const nix_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ test_dir, test_file });
        defer allocator.free(nix_path);

        const expect_path = try std.fmt.allocPrint(allocator, "{s}.expect", .{nix_path[0 .. nix_path.len - 4]});
        defer allocator.free(expect_path);

        const passed = testFile(allocator, nix_path, expect_path) catch false;

        try results.append(allocator, .{
            .name = test_file,
            .passed = passed,
        });
    }

    // Print results
    std.debug.print("\n{s}\n", .{sep});
    std.debug.print("Test Results:\n", .{});
    std.debug.print("{s}\n", .{sep});

    var pass_count: usize = 0;
    var fail_count: usize = 0;

    for (results.items) |result| {
        if (result.passed) {
            pass_count += 1;
            std.debug.print("✓ PASS: {s}\n", .{result.name});
        } else {
            fail_count += 1;
            std.debug.print("✗ FAIL: {s}\n", .{result.name});
        }
    }

    std.debug.print("\n{s}\n", .{sep});
    std.debug.print("Summary:\n", .{});
    std.debug.print("  Total:  {d} tests\n", .{results.items.len});
    std.debug.print("  Passed: {d} ({d:.1}%)\n", .{ pass_count, @as(f64, @floatFromInt(pass_count)) / @as(f64, @floatFromInt(results.items.len)) * 100.0 });
    std.debug.print("  Failed: {d} ({d:.1}%)\n", .{ fail_count, @as(f64, @floatFromInt(fail_count)) / @as(f64, @floatFromInt(results.items.len)) * 100.0 });
    std.debug.print("{s}\n", .{sep});

    if (fail_count > 0) {
        std.process.exit(1);
    }
}

fn testFile(allocator: std.mem.Allocator, nix_path: []const u8, expect_path: []const u8) !bool {
    // Read the .nix file
    const nix_file = std.fs.cwd().openFile(nix_path, .{}) catch |err| {
        std.debug.print("Error opening {s}: {any}\n", .{ nix_path, err });
        return false;
    };
    defer nix_file.close();

    const nix_source = nix_file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        std.debug.print("Error reading {s}: {any}\n", .{ nix_path, err });
        return false;
    };
    defer allocator.free(nix_source);

    // Parse it
    var cst = nix.parse(allocator, nix_source) catch |err| {
        std.debug.print("Error parsing {s}: {any}\n", .{ nix_path, err });
        return false;
    };
    defer cst.deinit();

    // Print the CST
    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);

    cst.printTree(output.writer(allocator)) catch |err| {
        std.debug.print("Error printing CST for {s}: {any}\n", .{ nix_path, err });
        return false;
    };

    // Try to read .expect file
    if (std.fs.cwd().openFile(expect_path, .{})) |expect_file| {
        defer expect_file.close();

        const expected = expect_file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
            std.debug.print("Error reading {s}: {any}\n", .{ expect_path, err });
            return false;
        };
        defer allocator.free(expected);

        // Compare
        return std.mem.eql(u8, output.items, expected);
    } else |_| {
        // No .expect file
        return false;
    }
}
