const std = @import("std");
const nix = @import("../root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Example Nix source code
    const source =
        \\let
        \\  name = "world";
        \\  greeting = "Hello, ${name}!";
        \\in greeting
    ;

    std.debug.print("Parsing Nix source:\n{s}\n\n", .{source});

    // Parse the source
    var cst = try nix.parse(allocator, source);
    defer cst.deinit();

    std.debug.print("Successfully parsed!\n\n", .{});

    // Print the CST structure
    std.debug.print("CST structure:\n", .{});
    try cst.printTree(std.io.getStdOut().writer());

    // Get some basic info
    const root = cst.root;
    std.debug.print("\nRoot node type: {s}\n", .{@tagName(root.kind.node)});
    std.debug.print("Number of children: {}\n", .{root.children.items.len});
    std.debug.print("Source span: {}..{}\n", .{ root.start, root.end });
}
