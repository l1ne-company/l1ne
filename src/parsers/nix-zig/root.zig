const std = @import("std");

pub const ast = @import("ast.zig");
pub const tokenizer = @import("tokenizer.zig");
pub const parser = @import("parser.zig");

pub const CST = ast.CST;
pub const Node = ast.Node;
pub const Parser = parser.Parser;
pub const Tokenizer = tokenizer.Tokenizer;

/// Parse Nix source code into a CST
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !CST {
    var p = try Parser.init(allocator, source);
    defer p.deinit();
    return try p.parse();
}

test "basic import" {
    _ = ast;
    _ = tokenizer;
    _ = parser;
}
