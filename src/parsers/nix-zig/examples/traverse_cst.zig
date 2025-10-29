const std = @import("std");
const nix = @import("../root.zig");
const ast = @import("../ast.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const source =
        \\{
        \\  name = "mypackage";
        \\  version = "1.0.0";
        \\  src = ./src;
        \\  dependencies = [ "foo" "bar" ];
        \\}
    ;

    var cst = try nix.parse(allocator, source);
    defer cst.deinit();

    std.debug.print("Traversing attribute set...\n\n", .{});

    // Traverse the CST and find all attribute assignments
    try findAttributes(&cst, cst.root, 0);
}

fn findAttributes(cst: *const ast.CST, node: *const ast.Node, depth: usize) !void {
    switch (node.kind) {
        .node => |kind| {
            switch (kind) {
                .NODE_ATTRPATH_VALUE => {
                    // This is an attribute assignment
                    const indent = depth * 2;
                    std.debug.print("{s}Found attribute: ", .{" " ** indent});

                    // Find the attribute name (first child of ATTRPATH)
                    for (node.children.items) |child| {
                        if (child.kind == .node and child.kind.node == .NODE_ATTRPATH) {
                            // Get the identifier from the attrpath
                            for (child.children.items) |attr_child| {
                                if (attr_child.kind == .node and attr_child.kind.node == .NODE_IDENT) {
                                    const name = cst.getText(attr_child);
                                    std.debug.print("{s}", .{name});
                                }
                            }
                            break;
                        }
                    }

                    // Find the value
                    var found_assign = false;
                    for (node.children.items) |child| {
                        if (found_assign) {
                            // Skip whitespace
                            if (child.kind == .token and child.kind.token == .TOKEN_WHITESPACE) {
                                continue;
                            }
                            // This is the value
                            const value_text = cst.getText(child);
                            std.debug.print(" = {s}\n", .{value_text});
                            break;
                        }
                        if (child.kind == .token and child.kind.token == .TOKEN_ASSIGN) {
                            found_assign = true;
                        }
                    }
                },
                else => {},
            }
        },
        .token => {},
    }

    // Recursively traverse children
    for (node.children.items) |child| {
        try findAttributes(cst, child, depth + 1);
    }
}
