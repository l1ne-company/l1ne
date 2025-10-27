const std = @import("std");

/// Token types in Nix
pub const TokenKind = enum {
    // Literals
    TOKEN_IDENT,
    TOKEN_INTEGER,
    TOKEN_FLOAT,
    TOKEN_STRING,
    TOKEN_PATH,
    TOKEN_URI,

    // Keywords
    TOKEN_IF,
    TOKEN_THEN,
    TOKEN_ELSE,
    TOKEN_LET,
    TOKEN_IN,
    TOKEN_REC,
    TOKEN_INHERIT,
    TOKEN_OR,
    TOKEN_ASSERT,
    TOKEN_WITH,

    // Operators
    TOKEN_ADD, // +
    TOKEN_SUB, // -
    TOKEN_MUL, // *
    TOKEN_DIV, // /
    TOKEN_UPDATE, // //
    TOKEN_CONCAT, // ++
    TOKEN_EQUAL, // ==
    TOKEN_NOT_EQUAL, // !=
    TOKEN_LESS, // <
    TOKEN_LESS_OR_EQ, // <=
    TOKEN_MORE, // >
    TOKEN_MORE_OR_EQ, // >=
    TOKEN_AND_AND, // &&
    TOKEN_OR_OR, // ||
    TOKEN_IMPLICATION, // ->
    TOKEN_INVERT, // !
    TOKEN_QUESTION, // ?
    TOKEN_PIPE_LEFT, // <|
    TOKEN_PIPE_RIGHT, // |>

    // Delimiters
    TOKEN_L_BRACE, // {
    TOKEN_R_BRACE, // }
    TOKEN_L_BRACK, // [
    TOKEN_R_BRACK, // ]
    TOKEN_L_PAREN, // (
    TOKEN_R_PAREN, // )
    TOKEN_SEMICOLON, // ;
    TOKEN_COLON, // :
    TOKEN_COMMA, // ,
    TOKEN_DOT, // .
    TOKEN_ELLIPSIS, // ...
    TOKEN_AT, // @
    TOKEN_ASSIGN, // =

    // Special
    TOKEN_WHITESPACE,
    TOKEN_COMMENT,
    TOKEN_EOF,
    TOKEN_ERROR,

    // String parts
    TOKEN_STRING_START, // " or ''
    TOKEN_STRING_END, // " or ''
    TOKEN_STRING_CONTENT,
    TOKEN_INTERPOL_START, // ${
    TOKEN_INTERPOL_END, // }
};

/// Node types in the CST
pub const NodeKind = enum {
    NODE_ROOT,
    NODE_ERROR,

    // Literals
    NODE_LITERAL,
    NODE_IDENT,
    NODE_STRING,
    NODE_INTERPOL,
    NODE_PATH,
    NODE_DYNAMIC,

    // Expressions
    NODE_APPLY,
    NODE_BIN_OP,
    NODE_UNARY_OP,
    NODE_PAREN,
    NODE_SELECT,
    NODE_IF_ELSE,
    NODE_LET_IN,
    NODE_WITH,
    NODE_ASSERT,
    NODE_LAMBDA,

    // Attribute sets
    NODE_ATTR_SET,
    NODE_ATTRPATH,
    NODE_ATTRPATH_VALUE,
    NODE_INHERIT,
    NODE_INHERIT_FROM,

    // Lists
    NODE_LIST,

    // Patterns
    NODE_PATTERN,
    NODE_PAT_BIND,
    NODE_PAT_ENTRY,
};

pub const NodeType = union(enum) {
    token: TokenKind,
    node: NodeKind,
};

/// CST Node - represents both tokens and nodes in a unified tree
pub const Node = struct {
    kind: NodeType,
    start: usize,
    end: usize,
    children: std.ArrayList(*Node),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, kind: NodeType, start: usize, end: usize) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .kind = kind,
            .start = start,
            .end = end,
            .children = std.ArrayList(*Node){},
            .allocator = allocator,
        };
        return node;
    }

    pub fn deinit(self: *Node) void {
        for (self.children.items) |child| {
            child.deinit();
        }
        self.children.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn addChild(self: *Node, child: *Node) !void {
        try self.children.append(self.allocator, child);
    }
};

/// Concrete Syntax Tree
pub const CST = struct {
    root: *Node,
    source: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: []const u8, root: *Node) CST {
        return .{
            .root = root,
            .source = source,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CST) void {
        self.root.deinit();
    }

    /// Get text content of a node
    pub fn getText(self: *const CST, node: *const Node) []const u8 {
        return self.source[node.start..node.end];
    }

    /// Print node recursively
    fn printNode(self: *const CST, writer: anytype, node: *const Node, indent: usize) !void {
        // Print indentation
        for (0..indent) |_| try writer.writeAll("  ");

        // Print node/token kind
        switch (node.kind) {
            .token => |t| try writer.print("{s}", .{@tagName(t)}),
            .node => |n| try writer.print("{s}", .{@tagName(n)}),
        }

        // Print span
        try writer.print("@{}..{}", .{ node.start, node.end });

        // For tokens, print the text content
        switch (node.kind) {
            .token => {
                const text = self.getText(node);
                try writer.writeAll(" \"");
                for (text) |ch| {
                    switch (ch) {
                        '\n' => try writer.writeAll("\\n"),
                        '\r' => try writer.writeAll("\\r"),
                        '\t' => try writer.writeAll("\\t"),
                        '\\' => try writer.writeAll("\\\\"),
                        '"' => try writer.writeAll("\\\""),
                        else => try writer.writeByte(ch),
                    }
                }
                try writer.writeAll("\"\n");
            },
            .node => {
                try writer.writeAll("\n");
                // Print children
                for (node.children.items) |child| {
                    try self.printNode(writer, child, indent + 1);
                }
            },
        }
    }

    /// Print the entire tree
    pub fn printTree(self: *const CST, writer: anytype) !void {
        try self.printNode(writer, self.root, 0);
        try writer.writeAll("\n");
    }
};
