const std = @import("std");
const ast = @import("ast.zig");
const tokenizer = @import("tokenizer.zig");

const TokenKind = ast.TokenKind;
const NodeKind = ast.NodeKind;
const Node = ast.Node;
const CST = ast.CST;
const Tokenizer = tokenizer.Tokenizer;
const Token = tokenizer.Token;

/// Operator precedence levels (lower number = lower precedence)
const Precedence = enum(u8) {
    LOWEST = 0,
    PIPE = 5, // |> <|
    IMPLICATION = 10, // ->
    OR = 20, // ||
    AND = 30, // &&
    EQUALITY = 40, // == !=
    COMPARISON = 50, // < <= > >=
    UPDATE = 60, // //
    NOT = 70, // ! (prefix)
    SUM = 80, // + -
    PRODUCT = 90, // * /
    CONCAT = 100, // ++
    HAS_ATTR = 110, // ?
    NEGATE = 120, // - (prefix)
    CALL = 130, // function application
    SELECT = 140, // . attribute selection
};

fn getInfixPrecedence(kind: TokenKind) ?Precedence {
    return switch (kind) {
        .TOKEN_PIPE_LEFT, .TOKEN_PIPE_RIGHT => .PIPE,
        .TOKEN_IMPLICATION => .IMPLICATION,
        .TOKEN_OR_OR => .OR,
        .TOKEN_AND_AND => .AND,
        .TOKEN_EQUAL, .TOKEN_NOT_EQUAL => .EQUALITY,
        .TOKEN_LESS, .TOKEN_LESS_OR_EQ, .TOKEN_MORE, .TOKEN_MORE_OR_EQ => .COMPARISON,
        .TOKEN_UPDATE => .UPDATE,
        .TOKEN_ADD, .TOKEN_SUB => .SUM,
        .TOKEN_MUL, .TOKEN_DIV => .PRODUCT,
        .TOKEN_CONCAT => .CONCAT,
        .TOKEN_QUESTION => .HAS_ATTR,
        .TOKEN_DOT => .SELECT,
        else => null,
    };
}

/// Get the precedence level immediately before the given precedence
fn getPrecedenceBefore(prec: Precedence) Precedence {
    return switch (prec) {
        .LOWEST => .LOWEST,
        .PIPE => .LOWEST,
        .IMPLICATION => .PIPE,
        .OR => .IMPLICATION,
        .AND => .OR,
        .EQUALITY => .AND,
        .COMPARISON => .EQUALITY,
        .UPDATE => .COMPARISON,
        .NOT => .UPDATE,
        .SUM => .NOT,
        .PRODUCT => .SUM,
        .CONCAT => .PRODUCT,
        .HAS_ATTR => .CONCAT,
        .NEGATE => .HAS_ATTR,
        .CALL => .NEGATE,
        .SELECT => .CALL,
    };
}

pub const Parser = struct {
    tokenizer: Tokenizer,
    allocator: std.mem.Allocator,
    source: []const u8,
    current_token: Token,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Parser {
        var tok = try Tokenizer.init(allocator, source);
        const first_token = try tok.next();
        return .{
            .tokenizer = tok,
            .allocator = allocator,
            .source = source,
            .current_token = first_token,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.tokenizer.deinit();
    }

    fn advance(self: *Parser) ParseError!void {
        self.current_token = try self.tokenizer.next();
    }

    fn peek(self: *Parser) TokenKind {
        return self.current_token.kind;
    }

    fn makeToken(self: *Parser, kind: TokenKind, start: usize, end: usize) !*Node {
        return try Node.init(self.allocator, .{ .token = kind }, start, end);
    }

    fn makeNode(self: *Parser, kind: NodeKind, start: usize) !*Node {
        return try Node.init(self.allocator, .{ .node = kind }, start, 0);
    }

    fn finishNode(node: *Node, end: usize) void {
        node.end = end;
    }

    fn consumeToken(self: *Parser) !*Node {
        const tok = try self.makeToken(self.current_token.kind, self.current_token.start, self.current_token.end);
        try self.advance();
        return tok;
    }

    fn expect(self: *Parser, kind: TokenKind) !*Node {
        if (self.current_token.kind != kind) {
            return error.UnexpectedToken;
        }
        return try self.consumeToken();
    }

    /// Skip whitespace and comments, advancing the parser
    fn skipWs(self: *Parser) ParseError!void {
        while (self.peek() == .TOKEN_WHITESPACE or self.peek() == .TOKEN_COMMENT) {
            try self.advance();
        }
    }

    /// Consume whitespace/comments and add to node
    fn consumeWs(self: *Parser, node: *Node) !void {
        while (self.peek() == .TOKEN_WHITESPACE or self.peek() == .TOKEN_COMMENT) {
            const ws = try self.consumeToken();
            try node.addChild(ws);
        }
    }

    pub fn parse(self: *Parser) !CST {
        const root = try self.makeNode(.NODE_ROOT, 0);
        errdefer root.deinit();

        const expr = try self.parseExpression(.LOWEST);
        try root.addChild(expr);

        finishNode(root, expr.end);
        return CST.init(self.allocator, self.source, root);
    }

    /// Parse expression with Pratt parsing
    fn parseExpression(self: *Parser, min_prec: Precedence) ParseError!*Node {
        try self.skipWs();

        // Parse prefix/primary
        var left = try self.parsePrefix();

        // Check for simple lambda: ident: expr or ident @ pattern: expr
        if (left.kind == .node and left.kind.node == .NODE_IDENT) {
            // Look ahead for : or @
            if (self.peek() == .TOKEN_WHITESPACE) {
                const saved_state = self.tokenizer.saveState();
                const saved_token = self.current_token;
                try self.skipWs();
                if (self.peek() == .TOKEN_COLON) {
                    // It's a simple lambda: ident: expr
                    const lambda_node = try self.makeNode(.NODE_LAMBDA, left.start);
                    errdefer lambda_node.deinit();
                    try lambda_node.addChild(left);
                    try self.consumeWs(lambda_node);
                    const colon = try self.consumeToken();
                    try lambda_node.addChild(colon);
                    try self.consumeWs(lambda_node);
                    const body = try self.parseExpression(.LOWEST);
                    try lambda_node.addChild(body);
                    finishNode(lambda_node, body.end);
                    return lambda_node;
                } else if (self.peek() == .TOKEN_AT) {
                    // It's a bind-left lambda: ident @ pattern: expr
                    const lambda_node = try self.makeNode(.NODE_LAMBDA, left.start);
                    errdefer lambda_node.deinit();

                    const pattern_node = try self.makeNode(.NODE_PATTERN, left.start);
                    errdefer pattern_node.deinit();

                    const bind_node = try self.makeNode(.NODE_PAT_BIND, left.start);
                    errdefer bind_node.deinit();
                    try bind_node.addChild(left);
                    try self.consumeWs(bind_node);
                    const at = try self.consumeToken();
                    try bind_node.addChild(at);
                    finishNode(bind_node, at.end);

                    try pattern_node.addChild(bind_node);
                    try self.consumeWs(pattern_node);

                    // Now parse the pattern part (e.g., { a, b })
                    if (self.peek() == .TOKEN_L_BRACE) {
                        const lbrace = try self.consumeToken();
                        try pattern_node.addChild(lbrace);
                        try self.consumeWs(pattern_node);

                        // Parse pattern entries
                        while (self.peek() != .TOKEN_R_BRACE and self.peek() != .TOKEN_EOF) {
                            if (self.peek() == .TOKEN_ELLIPSIS) {
                                const ellipsis = try self.consumeToken();
                                try pattern_node.addChild(ellipsis);
                                try self.consumeWs(pattern_node);
                                break;
                            }

                            const entry = try self.makeNode(.NODE_PAT_ENTRY, self.current_token.start);
                            errdefer entry.deinit();

                            const name = try self.parseIdent();
                            try entry.addChild(name);
                            try self.consumeWs(entry);

                            if (self.peek() == .TOKEN_QUESTION) {
                                const question = try self.consumeToken();
                                try entry.addChild(question);
                                try self.consumeWs(entry);

                                const default = try self.parseExpression(.LOWEST);
                                try entry.addChild(default);
                            }

                            finishNode(entry, if (entry.children.items.len > 0) entry.children.items[entry.children.items.len - 1].end else name.end);
                            try pattern_node.addChild(entry);

                            try self.consumeWs(pattern_node);
                            if (self.peek() == .TOKEN_COMMA) {
                                const comma = try self.consumeToken();
                                try pattern_node.addChild(comma);
                                try self.consumeWs(pattern_node);
                            } else {
                                break;
                            }
                        }

                        const rbrace = try self.expect(.TOKEN_R_BRACE);
                        try pattern_node.addChild(rbrace);
                        finishNode(pattern_node, rbrace.end);
                    }

                    try lambda_node.addChild(pattern_node);
                    try self.consumeWs(lambda_node);

                    const colon = try self.expect(.TOKEN_COLON);
                    try lambda_node.addChild(colon);
                    try self.consumeWs(lambda_node);

                    const body = try self.parseExpression(.LOWEST);
                    try lambda_node.addChild(body);
                    finishNode(lambda_node, body.end);
                    return lambda_node;
                } else {
                    // Not a lambda, restore
                    self.tokenizer.restoreState(saved_state);
                    self.current_token = saved_token;
                }
            } else if (self.peek() == .TOKEN_COLON) {
                // Lambda without whitespace: ident:expr
                const lambda_node = try self.makeNode(.NODE_LAMBDA, left.start);
                errdefer lambda_node.deinit();
                try lambda_node.addChild(left);
                const colon = try self.consumeToken();
                try lambda_node.addChild(colon);
                try self.consumeWs(lambda_node);
                const body = try self.parseExpression(.LOWEST);
                try lambda_node.addChild(body);
                finishNode(lambda_node, body.end);
                return lambda_node;
            } else if (self.peek() == .TOKEN_AT) {
                // Bind-left without leading whitespace: ident@{...}:expr
                // (same logic as above but without restoring state)
                const lambda_node = try self.makeNode(.NODE_LAMBDA, left.start);
                errdefer lambda_node.deinit();

                const pattern_node = try self.makeNode(.NODE_PATTERN, left.start);
                errdefer pattern_node.deinit();

                const bind_node = try self.makeNode(.NODE_PAT_BIND, left.start);
                errdefer bind_node.deinit();
                try bind_node.addChild(left);
                const at = try self.consumeToken();
                try bind_node.addChild(at);
                finishNode(bind_node, at.end);

                try pattern_node.addChild(bind_node);
                try self.consumeWs(pattern_node);

                if (self.peek() == .TOKEN_L_BRACE) {
                    const lbrace = try self.consumeToken();
                    try pattern_node.addChild(lbrace);
                    try self.consumeWs(pattern_node);

                    while (self.peek() != .TOKEN_R_BRACE and self.peek() != .TOKEN_EOF) {
                        if (self.peek() == .TOKEN_ELLIPSIS) {
                            const ellipsis = try self.consumeToken();
                            try pattern_node.addChild(ellipsis);
                            try self.consumeWs(pattern_node);
                            break;
                        }

                        const entry = try self.makeNode(.NODE_PAT_ENTRY, self.current_token.start);
                        errdefer entry.deinit();

                        const name = try self.parseIdent();
                        try entry.addChild(name);
                        try self.consumeWs(entry);

                        if (self.peek() == .TOKEN_QUESTION) {
                            const question = try self.consumeToken();
                            try entry.addChild(question);
                            try self.consumeWs(entry);

                            const default = try self.parseExpression(.LOWEST);
                            try entry.addChild(default);
                        }

                        finishNode(entry, if (entry.children.items.len > 0) entry.children.items[entry.children.items.len - 1].end else name.end);
                        try pattern_node.addChild(entry);

                        try self.consumeWs(pattern_node);
                        if (self.peek() == .TOKEN_COMMA) {
                            const comma = try self.consumeToken();
                            try pattern_node.addChild(comma);
                            try self.consumeWs(pattern_node);
                        } else {
                            break;
                        }
                    }

                    const rbrace = try self.expect(.TOKEN_R_BRACE);
                    try pattern_node.addChild(rbrace);
                    finishNode(pattern_node, rbrace.end);
                }

                try lambda_node.addChild(pattern_node);
                try self.consumeWs(lambda_node);

                const colon = try self.expect(.TOKEN_COLON);
                try lambda_node.addChild(colon);
                try self.consumeWs(lambda_node);

                const body = try self.parseExpression(.LOWEST);
                try lambda_node.addChild(body);
                finishNode(lambda_node, body.end);
                return lambda_node;
            }
        }

        // Parse infix operators
        while (true) {
            // Skip whitespace first to see what's next
            if (self.peek() == .TOKEN_WHITESPACE) {
                const saved_state = self.tokenizer.saveState();
                const saved_token = self.current_token;
                try self.skipWs();
                const next_token = self.peek();
                self.tokenizer.restoreState(saved_state);
                self.current_token = saved_token;

                // Check if next token (after whitespace) is an infix operator
                if (getInfixPrecedence(next_token)) |op_prec| {
                    if (@intFromEnum(op_prec) <= @intFromEnum(min_prec)) break;
                    // Don't skip whitespace - parseBinaryOp will consume it
                    left = try self.parseBinaryOp(left, op_prec);
                    continue;
                }

                // Check for function application
                const can_apply = switch (next_token) {
                    .TOKEN_IDENT,
                    .TOKEN_INTEGER,
                    .TOKEN_FLOAT,
                    .TOKEN_STRING_START,
                    .TOKEN_URI,
                    .TOKEN_PATH,
                    .TOKEN_L_BRACE,
                    .TOKEN_L_BRACK,
                    .TOKEN_L_PAREN,
                    .TOKEN_IF,
                    .TOKEN_LET,
                    .TOKEN_WITH,
                    .TOKEN_ASSERT,
                    .TOKEN_REC,
                    .TOKEN_SUB,
                    .TOKEN_INVERT,
                    => true,
                    else => false,
                };

                if (can_apply and @intFromEnum(Precedence.CALL) > @intFromEnum(min_prec)) {
                    left = try self.parseFunctionApplication(left);
                    continue;
                }
            }

            // Check for infix binary operators (no whitespace)
            if (getInfixPrecedence(self.peek())) |op_prec| {
                if (@intFromEnum(op_prec) <= @intFromEnum(min_prec)) break;
                left = try self.parseBinaryOp(left, op_prec);
                continue;
            }

            // Check for select (. operator)
            if (self.peek() == .TOKEN_DOT) {
                if (@intFromEnum(Precedence.SELECT) <= @intFromEnum(min_prec)) break;
                left = try self.parseSelect(left);
                continue;
            }

            // No more operators
            break;
        }

        return left;
    }

    const ParseError = error{ OutOfMemory, UnexpectedToken };

    fn parsePrefix(self: *Parser) ParseError!*Node {
        const start = self.current_token.start;

        return switch (self.peek()) {
            .TOKEN_INTEGER, .TOKEN_FLOAT, .TOKEN_URI, .TOKEN_PATH => try self.parseLiteral(),
            .TOKEN_IDENT => try self.parseIdent(),
            .TOKEN_STRING_START => try self.parseString(),
            .TOKEN_L_BRACE => blk: {
                // Look ahead to distinguish pattern from attr set
                const saved_state = self.tokenizer.saveState();
                const saved_token = self.current_token;
                var looks_like_pattern = false;

                try self.advance(); // skip {
                try self.skipWs();

                // Check for pattern indicators
                switch (self.peek()) {
                    .TOKEN_R_BRACE => {
                        // Empty braces - check what follows
                        try self.advance();
                        try self.skipWs();
                        if (self.peek() == .TOKEN_COLON or self.peek() == .TOKEN_AT) {
                            looks_like_pattern = true;
                        }
                    },
                    .TOKEN_ELLIPSIS => {
                        // { ... - definitely a pattern
                        looks_like_pattern = true;
                    },
                    .TOKEN_IDENT => {
                        // Need to look further
                        try self.advance();
                        try self.skipWs();
                        if (self.peek() == .TOKEN_COMMA or self.peek() == .TOKEN_QUESTION or
                            self.peek() == .TOKEN_R_BRACE)
                        {
                            looks_like_pattern = true;
                        }
                    },
                    else => {},
                }

                // Restore position
                self.tokenizer.restoreState(saved_state);
                self.current_token = saved_token;

                if (looks_like_pattern) {
                    break :blk try self.parseLambda();
                } else {
                    break :blk try self.parseAttrSet();
                }
            },
            .TOKEN_L_BRACK => try self.parseList(),
            .TOKEN_L_PAREN => try self.parseParenthesized(),
            .TOKEN_IF => try self.parseIfElse(),
            .TOKEN_LET => try self.parseLetIn(),
            .TOKEN_WITH => try self.parseWith(),
            .TOKEN_ASSERT => try self.parseAssert(),
            .TOKEN_REC => try self.parseRecAttrSet(),
            .TOKEN_SUB, .TOKEN_INVERT => try self.parseUnaryOp(),
            else => blk: {
                // Error: unexpected token
                const node = try self.makeNode(.NODE_ERROR, start);
                const tok = try self.consumeToken();
                try node.addChild(tok);
                finishNode(node, tok.end);
                break :blk node;
            },
        };
    }

    fn canStartExpression(self: *Parser) bool {
        return switch (self.peek()) {
            .TOKEN_IDENT,
            .TOKEN_INTEGER,
            .TOKEN_FLOAT,
            .TOKEN_STRING_START,
            .TOKEN_L_BRACE,
            .TOKEN_L_BRACK,
            .TOKEN_L_PAREN,
            .TOKEN_IF,
            .TOKEN_LET,
            .TOKEN_WITH,
            .TOKEN_ASSERT,
            .TOKEN_REC,
            .TOKEN_SUB,
            .TOKEN_INVERT,
            => true,
            else => false,
        };
    }

    fn parseLiteral(self: *Parser) ParseError!*Node {
        const start = self.current_token.start;
        const node = try self.makeNode(.NODE_LITERAL, start);
        const tok = try self.consumeToken();
        try node.addChild(tok);
        finishNode(node, tok.end);
        return node;
    }

    fn parseIdent(self: *Parser) ParseError!*Node {
        const start = self.current_token.start;
        const node = try self.makeNode(.NODE_IDENT, start);
        const tok = try self.consumeToken();
        try node.addChild(tok);
        finishNode(node, tok.end);
        return node;
    }

    fn parseString(self: *Parser) ParseError!*Node {
        const start = self.current_token.start;
        const node = try self.makeNode(.NODE_STRING, start);
        errdefer node.deinit();

        // Expect TOKEN_STRING_START
        const start_tok = try self.expect(.TOKEN_STRING_START);
        try node.addChild(start_tok);

        // Loop consuming string content and interpolations
        while (true) {
            switch (self.peek()) {
                .TOKEN_STRING_CONTENT => {
                    const content = try self.consumeToken();
                    try node.addChild(content);
                },
                .TOKEN_INTERPOL_START => {
                    // Parse interpolation: ${ expr }
                    const interp_node = try self.makeNode(.NODE_INTERPOL, self.current_token.start);
                    errdefer interp_node.deinit();

                    const interp_start = try self.consumeToken();
                    try interp_node.addChild(interp_start);

                    // Parse the expression inside
                    const expr = try self.parseExpression(.LOWEST);
                    try interp_node.addChild(expr);

                    // Consume whitespace before closing }
                    try self.consumeWs(interp_node);

                    // Expect TOKEN_INTERPOL_END
                    const interp_end = try self.expect(.TOKEN_INTERPOL_END);
                    try interp_node.addChild(interp_end);

                    finishNode(interp_node, interp_end.end);
                    try node.addChild(interp_node);
                },
                .TOKEN_STRING_END => {
                    const end_tok = try self.consumeToken();
                    try node.addChild(end_tok);
                    finishNode(node, end_tok.end);
                    return node;
                },
                else => {
                    // Error: unexpected token in string
                    finishNode(node, self.current_token.end);
                    return node;
                },
            }
        }
    }

    fn parseUnaryOp(self: *Parser) ParseError!*Node {
        const start = self.current_token.start;
        const node = try self.makeNode(.NODE_UNARY_OP, start);
        errdefer node.deinit();

        const op = try self.consumeToken();
        try node.addChild(op);

        const prec: Precedence = if (op.kind == .token and op.kind.token == .TOKEN_INVERT) .NOT else .NEGATE;
        const expr = try self.parseExpression(prec);
        try node.addChild(expr);

        finishNode(node, expr.end);
        return node;
    }

    fn parseBinaryOp(self: *Parser, left: *Node, prec: Precedence) ParseError!*Node {
        const start = left.start;
        const node = try self.makeNode(.NODE_BIN_OP, start);
        errdefer node.deinit();

        try node.addChild(left);
        try self.consumeWs(node);

        const op_tok = try self.consumeToken();
        const op_kind = op_tok.kind;
        try node.addChild(op_tok);
        try self.consumeWs(node);

        // Check if operator is right-associative
        const is_right_assoc = switch (op_kind) {
            .token => |t| switch (t) {
                .TOKEN_CONCAT, // ++
                .TOKEN_UPDATE, // //
                .TOKEN_IMPLICATION, // ->
                .TOKEN_PIPE_LEFT, // <|
                => true,
                else => false,
            },
            else => false,
        };

        // For right-associative operators, parse right side with one level lower precedence
        // This allows the same operator to bind tighter on the right: a ++ b ++ c -> a ++ (b ++ c)
        // For left-associative operators, parse right side with same precedence
        // This makes them bind from left to right: a + b + c -> (a + b) + c
        const right_prec: Precedence = if (is_right_assoc)
            getPrecedenceBefore(prec)
        else
            prec;

        const right = try self.parseExpression(right_prec);
        try node.addChild(right);

        finishNode(node, right.end);
        return node;
    }

    fn parseFunctionApplication(self: *Parser, func: *Node) ParseError!*Node {
        const start = func.start;
        const node = try self.makeNode(.NODE_APPLY, start);
        errdefer node.deinit();

        try node.addChild(func);
        try self.consumeWs(node);

        // Parse argument with CALL precedence to get left-associativity
        const arg = try self.parseExpression(.CALL);
        try node.addChild(arg);

        finishNode(node, arg.end);
        return node;
    }

    fn parseSelect(self: *Parser, left: *Node) ParseError!*Node {
        const start = left.start;
        const node = try self.makeNode(.NODE_SELECT, start);
        errdefer node.deinit();

        try node.addChild(left);

        const dot = try self.expect(.TOKEN_DOT);
        try node.addChild(dot);

        // Parse attribute name or dynamic attribute
        if (self.peek() == .TOKEN_IDENT) {
            const attr = try self.parseIdent();
            try node.addChild(attr);
            finishNode(node, attr.end);
        } else if (self.peek() == .TOKEN_STRING_START or self.peek() == .TOKEN_L_BRACE) {
            const attr = try self.parsePrefix();
            try node.addChild(attr);
            finishNode(node, attr.end);
        } else {
            finishNode(node, dot.end);
        }

        // Check for 'or' default
        if (self.peek() == .TOKEN_WHITESPACE) {
            const saved_state = self.tokenizer.saveState();
            const saved_token = self.current_token;
            try self.skipWs();
            if (self.peek() == .TOKEN_OR) {
                const or_tok = try self.consumeToken();
                try node.addChild(or_tok);
                try self.consumeWs(node);
                const default = try self.parseExpression(.SELECT);
                try node.addChild(default);
                finishNode(node, default.end);
            } else {
                self.tokenizer.restoreState(saved_state);
                self.current_token = saved_token;
            }
        }

        return node;
    }

    fn parseParenthesized(self: *Parser) ParseError!*Node {
        const start = self.current_token.start;

        // Check if it's a lambda pattern
        // We need to look ahead to see if there's a : after the )
        const saved_state = self.tokenizer.saveState();
        const saved_token = self.current_token;
        var paren_depth: i32 = 0;
        var is_pattern = false;

        try self.advance(); // skip (
        paren_depth = 1;
        while (paren_depth > 0 and self.peek() != .TOKEN_EOF) {
            if (self.peek() == .TOKEN_L_PAREN) paren_depth += 1;
            if (self.peek() == .TOKEN_R_PAREN) paren_depth -= 1;
            if (paren_depth == 0) break;
            try self.advance();
        }
        if (self.peek() == .TOKEN_R_PAREN) try self.advance();
        try self.skipWs();
        if (self.peek() == .TOKEN_COLON) {
            is_pattern = true;
        }

        // Restore position
        self.tokenizer.restoreState(saved_state);
        self.current_token = saved_token;

        if (is_pattern) {
            return try self.parseLambda();
        }

        // Regular parenthesized expression
        const node = try self.makeNode(.NODE_PAREN, start);
        errdefer node.deinit();

        const lparen = try self.expect(.TOKEN_L_PAREN);
        try node.addChild(lparen);
        try self.consumeWs(node);

        const expr = try self.parseExpression(.LOWEST);
        try node.addChild(expr);
        try self.consumeWs(node);

        if (self.peek() == .TOKEN_R_PAREN) {
            const rparen = try self.consumeToken();
            try node.addChild(rparen);
            finishNode(node, rparen.end);
        } else {
            finishNode(node, expr.end);
        }

        return node;
    }

    fn parseLambda(self: *Parser) ParseError!*Node {
        const start = self.current_token.start;
        const node = try self.makeNode(.NODE_LAMBDA, start);
        errdefer node.deinit();

        // Parse pattern
        if (self.peek() == .TOKEN_L_BRACE or self.peek() == .TOKEN_L_PAREN) {
            const pattern = try self.parsePattern();
            try node.addChild(pattern);
        } else if (self.peek() == .TOKEN_IDENT) {
            const param = try self.parseIdent();
            try node.addChild(param);
        }

        try self.consumeWs(node);

        if (self.peek() == .TOKEN_COLON) {
            const colon = try self.consumeToken();
            try node.addChild(colon);
        }

        try self.consumeWs(node);

        const body = try self.parseExpression(.LOWEST);
        try node.addChild(body);

        finishNode(node, body.end);
        return node;
    }

    fn parsePattern(self: *Parser) ParseError!*Node {
        const start = self.current_token.start;
        const node = try self.makeNode(.NODE_PATTERN, start);
        errdefer node.deinit();

        if (self.peek() == .TOKEN_L_BRACE) {
            const lbrace = try self.consumeToken();
            try node.addChild(lbrace);
            try self.consumeWs(node);

            while (self.peek() != .TOKEN_R_BRACE and self.peek() != .TOKEN_EOF) {
                // Check for ellipsis first
                if (self.peek() == .TOKEN_ELLIPSIS) {
                    const ellipsis = try self.consumeToken();
                    try node.addChild(ellipsis);
                    try self.consumeWs(node);
                    break;
                }

                // Parse pattern entry: name ? default
                const entry_start = self.current_token.start;
                const entry = try self.makeNode(.NODE_PAT_ENTRY, entry_start);
                errdefer entry.deinit();

                const name = try self.parseIdent();
                try entry.addChild(name);
                try self.consumeWs(entry);

                if (self.peek() == .TOKEN_QUESTION) {
                    const question = try self.consumeToken();
                    try entry.addChild(question);
                    try self.consumeWs(entry);

                    const default = try self.parseExpression(.LOWEST);
                    try entry.addChild(default);
                }

                finishNode(entry, if (entry.children.items.len > 0) entry.children.items[entry.children.items.len - 1].end else name.end);
                try node.addChild(entry);

                try self.consumeWs(node);
                if (self.peek() == .TOKEN_COMMA) {
                    const comma = try self.consumeToken();
                    try node.addChild(comma);
                    try self.consumeWs(node);
                } else {
                    // No comma, so we're done with entries
                    break;
                }
            }

            if (self.peek() == .TOKEN_R_BRACE) {
                const rbrace = try self.consumeToken();
                try node.addChild(rbrace);
                finishNode(node, rbrace.end);
            } else {
                finishNode(node, self.current_token.start);
            }

            // Check for @ binding
            try self.consumeWs(node);
            if (self.peek() == .TOKEN_AT) {
                const at_node = try self.makeNode(.NODE_PAT_BIND, node.start);
                const at = try self.consumeToken();
                try at_node.addChild(node);
                try at_node.addChild(at);
                try self.consumeWs(at_node);

                const ident = try self.parseIdent();
                try at_node.addChild(ident);
                finishNode(at_node, ident.end);
                return at_node;
            }
        } else if (self.peek() == .TOKEN_IDENT) {
            // Simple identifier parameter
            const ident = try self.parseIdent();
            return ident;
        }

        return node;
    }

    fn parseIfElse(self: *Parser) ParseError!*Node {
        const start = self.current_token.start;
        const node = try self.makeNode(.NODE_IF_ELSE, start);
        errdefer node.deinit();

        const if_tok = try self.expect(.TOKEN_IF);
        try node.addChild(if_tok);
        try self.consumeWs(node);

        const cond = try self.parseExpression(.LOWEST);
        try node.addChild(cond);
        try self.consumeWs(node);

        if (self.peek() == .TOKEN_THEN) {
            const then_tok = try self.consumeToken();
            try node.addChild(then_tok);
        }
        try self.consumeWs(node);

        const then_expr = try self.parseExpression(.LOWEST);
        try node.addChild(then_expr);
        try self.consumeWs(node);

        if (self.peek() == .TOKEN_ELSE) {
            const else_tok = try self.consumeToken();
            try node.addChild(else_tok);
        }
        try self.consumeWs(node);

        const else_expr = try self.parseExpression(.LOWEST);
        try node.addChild(else_expr);

        finishNode(node, else_expr.end);
        return node;
    }

    fn parseLetIn(self: *Parser) ParseError!*Node {
        const start = self.current_token.start;
        const node = try self.makeNode(.NODE_LET_IN, start);
        errdefer node.deinit();

        const let_tok = try self.expect(.TOKEN_LET);
        try node.addChild(let_tok);

        while (true) {
            try self.consumeWs(node);
            if (self.peek() == .TOKEN_IN or self.peek() == .TOKEN_EOF) break;

            if (self.peek() == .TOKEN_INHERIT) {
                const inherit_node = try self.parseInherit();
                try node.addChild(inherit_node);
            } else {
                const binding = try self.parseAttrPathValue();
                try node.addChild(binding);
            }
        }

        if (self.peek() == .TOKEN_IN) {
            const in_tok = try self.consumeToken();
            try node.addChild(in_tok);
        }
        try self.consumeWs(node);

        const body = try self.parseExpression(.LOWEST);
        try node.addChild(body);

        finishNode(node, body.end);
        return node;
    }

    fn parseWith(self: *Parser) ParseError!*Node {
        const start = self.current_token.start;
        const node = try self.makeNode(.NODE_WITH, start);
        errdefer node.deinit();

        const with_tok = try self.expect(.TOKEN_WITH);
        try node.addChild(with_tok);
        try self.consumeWs(node);

        const env = try self.parseExpression(.LOWEST);
        try node.addChild(env);
        try self.consumeWs(node);

        if (self.peek() == .TOKEN_SEMICOLON) {
            const semi = try self.consumeToken();
            try node.addChild(semi);
        }
        try self.consumeWs(node);

        const body = try self.parseExpression(.LOWEST);
        try node.addChild(body);

        finishNode(node, body.end);
        return node;
    }

    fn parseAssert(self: *Parser) ParseError!*Node {
        const start = self.current_token.start;
        const node = try self.makeNode(.NODE_ASSERT, start);
        errdefer node.deinit();

        const assert_tok = try self.expect(.TOKEN_ASSERT);
        try node.addChild(assert_tok);
        try self.consumeWs(node);

        const cond = try self.parseExpression(.LOWEST);
        try node.addChild(cond);
        try self.consumeWs(node);

        if (self.peek() == .TOKEN_SEMICOLON) {
            const semi = try self.consumeToken();
            try node.addChild(semi);
        }
        try self.consumeWs(node);

        const body = try self.parseExpression(.LOWEST);
        try node.addChild(body);

        finishNode(node, body.end);
        return node;
    }

    fn parseRecAttrSet(self: *Parser) ParseError!*Node {
        const start = self.current_token.start;
        const node = try self.makeNode(.NODE_ATTR_SET, start);
        errdefer node.deinit();

        const rec_tok = try self.expect(.TOKEN_REC);
        try node.addChild(rec_tok);
        try self.skipWs();

        const lbrace = try self.expect(.TOKEN_L_BRACE);
        try node.addChild(lbrace);

        // Rest is same as parseAttrSet
        while (true) {
            try self.consumeWs(node);
            if (self.peek() == .TOKEN_R_BRACE or self.peek() == .TOKEN_EOF) break;

            if (self.peek() == .TOKEN_INHERIT) {
                const inherit = try self.parseInherit();
                try node.addChild(inherit);
            } else {
                const binding = try self.parseAttrPathValue();
                try node.addChild(binding);
            }
        }

        try self.consumeWs(node);
        if (self.peek() == .TOKEN_R_BRACE) {
            const rbrace = try self.consumeToken();
            try node.addChild(rbrace);
            finishNode(node, rbrace.end);
        } else {
            finishNode(node, self.current_token.start);
        }

        return node;
    }

    fn parseAttrSet(self: *Parser) ParseError!*Node {
        const start = self.current_token.start;
        const node = try self.makeNode(.NODE_ATTR_SET, start);
        errdefer node.deinit();

        const lbrace = try self.expect(.TOKEN_L_BRACE);
        try node.addChild(lbrace);

        while (true) {
            try self.consumeWs(node);
            if (self.peek() == .TOKEN_R_BRACE or self.peek() == .TOKEN_EOF) break;

            if (self.peek() == .TOKEN_INHERIT) {
                const inherit_node = try self.parseInherit();
                try node.addChild(inherit_node);
            } else {
                const attr_val = try self.parseAttrPathValue();
                try node.addChild(attr_val);
            }
        }

        try self.consumeWs(node);
        if (self.peek() == .TOKEN_R_BRACE) {
            const rbrace = try self.consumeToken();
            try node.addChild(rbrace);
            finishNode(node, rbrace.end);
        } else {
            finishNode(node, self.current_token.start);
        }

        return node;
    }

    fn parseInherit(self: *Parser) ParseError!*Node {
        const start = self.current_token.start;
        const node = try self.makeNode(.NODE_INHERIT, start);
        errdefer node.deinit();

        const inherit_tok = try self.expect(.TOKEN_INHERIT);
        try node.addChild(inherit_tok);
        try self.consumeWs(node);

        // Check for (source)
        if (self.peek() == .TOKEN_L_PAREN) {
            const from_start = self.current_token.start;
            const from_node = try self.makeNode(.NODE_INHERIT_FROM, from_start);
            errdefer from_node.deinit();

            const lparen = try self.consumeToken();
            try from_node.addChild(lparen);
            try self.consumeWs(from_node);

            const source = try self.parseExpression(.LOWEST);
            try from_node.addChild(source);
            try self.consumeWs(from_node);

            if (self.peek() == .TOKEN_R_PAREN) {
                const rparen = try self.consumeToken();
                try from_node.addChild(rparen);
            }

            finishNode(from_node, self.current_token.start);
            try node.addChild(from_node);
            try self.consumeWs(node);
        }

        // Parse inherited attributes (identifiers, strings, or dynamic)
        while (self.peek() == .TOKEN_IDENT or self.peek() == .TOKEN_STRING_START or self.peek() == .TOKEN_INTERPOL_START) {
            if (self.peek() == .TOKEN_IDENT) {
                const ident = try self.parseIdent();
                try node.addChild(ident);
            } else if (self.peek() == .TOKEN_STRING_START) {
                const str = try self.parseString();
                try node.addChild(str);
            } else if (self.peek() == .TOKEN_INTERPOL_START) {
                // Dynamic attribute ${expr}
                const dyn_node = try self.makeNode(.NODE_DYNAMIC, self.current_token.start);
                errdefer dyn_node.deinit();

                const interp_start = try self.expect(.TOKEN_INTERPOL_START);
                try dyn_node.addChild(interp_start);

                const expr = try self.parseExpression(.LOWEST);
                try dyn_node.addChild(expr);

                try self.consumeWs(dyn_node);
                const interp_end = try self.expect(.TOKEN_INTERPOL_END);
                try dyn_node.addChild(interp_end);

                finishNode(dyn_node, interp_end.end);
                try node.addChild(dyn_node);
            }
            try self.consumeWs(node);
        }

        if (self.peek() == .TOKEN_SEMICOLON) {
            const semi = try self.consumeToken();
            try node.addChild(semi);
            finishNode(node, semi.end);
        } else {
            finishNode(node, self.current_token.start);
        }

        return node;
    }

    fn parseAttrPathValue(self: *Parser) ParseError!*Node {
        const start = self.current_token.start;
        const node = try self.makeNode(.NODE_ATTRPATH_VALUE, start);
        errdefer node.deinit();

        const attrpath = try self.parseAttrPath();
        try node.addChild(attrpath);

        while (self.peek() == .TOKEN_WHITESPACE) {
            const ws = try self.consumeToken();
            try node.addChild(ws);
        }

        if (self.peek() == .TOKEN_ASSIGN) {
            const assign = try self.consumeToken();
            try node.addChild(assign);
        }

        while (self.peek() == .TOKEN_WHITESPACE) {
            const ws = try self.consumeToken();
            try node.addChild(ws);
        }

        const value = try self.parseExpression(.LOWEST);
        try node.addChild(value);

        if (self.peek() == .TOKEN_SEMICOLON) {
            const semi = try self.consumeToken();
            try node.addChild(semi);
            finishNode(node, semi.end);
        } else {
            finishNode(node, value.end);
        }

        return node;
    }

    fn parseAttrPath(self: *Parser) ParseError!*Node {
        const start = self.current_token.start;
        const node = try self.makeNode(.NODE_ATTRPATH, start);
        errdefer node.deinit();

        // Parse attribute path components (a.b.c or "a"."b" or ${expr}.foo)
        while (true) {
            if (self.peek() == .TOKEN_IDENT) {
                const ident = try self.parseIdent();
                try node.addChild(ident);
                finishNode(node, ident.end);
            } else if (self.peek() == .TOKEN_STRING_START) {
                const str = try self.parseString();
                try node.addChild(str);
                finishNode(node, str.end);
            } else if (self.peek() == .TOKEN_INTERPOL_START) {
                // Dynamic attribute ${expr}
                const dyn_node = try self.makeNode(.NODE_DYNAMIC, self.current_token.start);
                errdefer dyn_node.deinit();

                const interp_start = try self.expect(.TOKEN_INTERPOL_START);
                try dyn_node.addChild(interp_start);

                const expr = try self.parseExpression(.LOWEST);
                try dyn_node.addChild(expr);

                const interp_end = try self.expect(.TOKEN_INTERPOL_END);
                try dyn_node.addChild(interp_end);

                finishNode(dyn_node, interp_end.end);
                try node.addChild(dyn_node);
                finishNode(node, dyn_node.end);
            } else if (self.peek() == .TOKEN_L_BRACE) {
                // Dynamic attribute ${expr}
                const dyn = try self.parsePrefix();
                try node.addChild(dyn);
                finishNode(node, dyn.end);
            } else {
                break;
            }

            // Check for dot to continue path
            if (self.peek() != .TOKEN_DOT) break;

            const dot = try self.consumeToken();
            try node.addChild(dot);
        }

        return node;
    }

    fn parseList(self: *Parser) ParseError!*Node {
        const start = self.current_token.start;
        const node = try self.makeNode(.NODE_LIST, start);
        errdefer node.deinit();

        const lbracket = try self.expect(.TOKEN_L_BRACK);
        try node.addChild(lbracket);

        while (true) {
            // Consume whitespace and comments
            while (self.peek() == .TOKEN_WHITESPACE or self.peek() == .TOKEN_COMMENT) {
                const ws = try self.consumeToken();
                try node.addChild(ws);
            }

            if (self.peek() == .TOKEN_R_BRACK or self.peek() == .TOKEN_EOF) break;

            // Parse list element - use SELECT precedence to prevent function application
            const elem = try self.parseExpression(.SELECT);
            try node.addChild(elem);
        }

        if (self.peek() == .TOKEN_R_BRACK) {
            const rbracket = try self.consumeToken();
            try node.addChild(rbracket);
            finishNode(node, rbracket.end);
        } else {
            finishNode(node, self.current_token.start);
        }

        return node;
    }
};
