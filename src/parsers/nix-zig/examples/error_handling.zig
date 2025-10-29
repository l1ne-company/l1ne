const std = @import("std");
const nix = @import("../root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Example 1: Valid Nix code
    std.debug.print("=== Example 1: Valid code ===\n", .{});
    try parseAndReport(allocator,
        \\let x = 1; in x
    );

    // Example 2: Invalid Nix code (syntax error)
    std.debug.print("\n=== Example 2: Syntax error ===\n", .{});
    try parseAndReport(allocator,
        \\let x = ; in x
    );

    // Example 3: Incomplete expression
    std.debug.print("\n=== Example 3: Incomplete expression ===\n", .{});
    try parseAndReport(allocator,
        \\let x = 1
    );

    // Example 4: Complex valid code
    std.debug.print("\n=== Example 4: Complex valid code ===\n", .{});
    try parseAndReport(allocator,
        \\{
        \\  name = "test";
        \\  version = "1.0";
        \\  src = ./src;
        \\}
    );
}

fn parseAndReport(allocator: std.mem.Allocator, source: []const u8) !void {
    std.debug.print("Parsing: {s}\n", .{source});

    var cst = nix.parse(allocator, source) catch |err| {
        std.debug.print("✗ Parse failed: {}\n", .{err});
        return;
    };
    defer cst.deinit();

    std.debug.print("✓ Parse successful!\n", .{});

    // Check for error nodes in the CST
    var has_errors = false;
    try checkForErrors(cst.root, &has_errors);

    if (has_errors) {
        std.debug.print("⚠  Warning: CST contains error nodes\n", .{});
    } else {
        std.debug.print("✓ No error nodes in CST\n", .{});
    }
}

fn checkForErrors(node: *const @import("../ast.zig").Node, has_errors: *bool) !void {
    switch (node.kind) {
        .node => |kind| {
            if (kind == .NODE_ERROR) {
                has_errors.* = true;
            }
        },
        .token => |kind| {
            if (kind == .TOKEN_ERROR) {
                has_errors.* = true;
            }
        },
    }

    for (node.children.items) |child| {
        try checkForErrors(child, has_errors);
    }
}
