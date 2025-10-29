const std = @import("std");
const nix = @import("../root.zig");
const ast = @import("../ast.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const source =
        \\let
        \\  name = "Alice";
        \\  age = 30;
        \\  greeting = "Hello, ${name}! You are ${toString age} years old.";
        \\  path = ./configs/${name}/settings.nix;
        \\in { inherit greeting path; }
    ;

    var cst = try nix.parse(allocator, source);
    defer cst.deinit();

    std.debug.print("Source:\n{s}\n\n", .{source});
    std.debug.print("Finding all interpolations...\n\n", .{});

    try findInterpolations(&cst, cst.root);
}

fn findInterpolations(cst: *const ast.CST, node: *const ast.Node) !void {
    switch (node.kind) {
        .node => |kind| {
            if (kind == .NODE_INTERPOL) {
                std.debug.print("Found interpolation at {}..{}: ", .{ node.start, node.end });

                // Get the full interpolation text including ${}
                const full_text = cst.getText(node);
                std.debug.print("{s}\n", .{full_text});

                // Extract just the expression inside ${}
                for (node.children.items) |child| {
                    // Skip the ${ and } tokens, print the expression
                    if (child.kind == .token) {
                        const token_kind = child.kind.token;
                        if (token_kind != .TOKEN_INTERPOL_START and token_kind != .TOKEN_INTERPOL_END) {
                            const expr_text = cst.getText(child);
                            std.debug.print("  Expression: {s}\n", .{expr_text});
                        }
                    } else {
                        // It's a node (the expression)
                        const expr_text = cst.getText(child);
                        std.debug.print("  Expression: {s}\n", .{expr_text});
                    }
                }
                std.debug.print("\n", .{});
            }
        },
        .token => {},
    }

    // Recursively traverse children
    for (node.children.items) |child| {
        try findInterpolations(cst, child);
    }
}
