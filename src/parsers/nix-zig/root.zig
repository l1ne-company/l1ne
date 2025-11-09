const std = @import("std");

pub const ast = @import("ast.zig");
pub const tokenizer = @import("tokenizer.zig");
pub const parser = @import("parser.zig");

pub const CST = ast.CST;
pub const Node = ast.Node;
pub const Parser = parser.Parser;
pub const Tokenizer = tokenizer.Tokenizer;
pub const Diagnostic = parser.Diagnostic;
pub const DiagnosticKind = parser.DiagnosticKind;
pub const Span = parser.Span;

pub fn parseWithDiagnostics(
    allocator: std.mem.Allocator,
    source: []const u8,
    diagnostics: ?*Diagnostic,
) !CST {
    if (diagnostics) |diag| {
        diag.* = .{};
    }
    var p = try Parser.init(allocator, source, diagnostics);
    defer p.deinit();
    return try p.parse();
}

/// Parse Nix source code into a CST
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !CST {
    return parseWithDiagnostics(allocator, source, null);
}

test "basic import" {
    _ = ast;
    _ = tokenizer;
    _ = parser;
}
