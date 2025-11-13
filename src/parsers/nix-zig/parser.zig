const std = @import("std");
const ast = @import("ast.zig");
const tokenizer = @import("tokenizer.zig");

const TokenKind = ast.TokenKind;
const NodeKind = ast.NodeKind;
const Node = ast.Node;
const CST = ast.CST;
const Tokenizer = tokenizer.Tokenizer;
const Token = tokenizer.Token;

pub const Span = struct {
    start: usize,
    end: usize,
};

pub const DiagnosticKind = enum {
    unexpected_token,
    postfix_limit,
    internal,
};

pub const Diagnostic = struct {
    kind: DiagnosticKind = .internal,
    span: Span = .{ .start = 0, .end = 0 },
    got_token: ?TokenKind = null,
    expected_token: ?TokenKind = null,
    limit: usize = 0,
    note_len: usize = 0,
    note_buf: [128]u8 = undefined,

    pub fn note(self: *const Diagnostic) []const u8 {
        return self.note_buf[0..self.note_len];
    }
};

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
        // NOTE: QUESTION and DOT are NOT here - handled specially by parseHasAttr and parseSelect
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
    diagnostics: ?*Diagnostic,

    pub fn init(allocator: std.mem.Allocator, source: []const u8, diagnostics: ?*Diagnostic) !Parser {
        var tok = try Tokenizer.init(allocator, source);
        const first_token = try tok.next();
        return .{
            .tokenizer = tok,
            .allocator = allocator,
            .source = source,
            .current_token = first_token,
            .diagnostics = diagnostics,
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
            self.recordUnexpectedToken(kind, "mismatched token");
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

    fn peekAfterTrivia(self: *Parser, target: TokenKind) ParseError!bool {
        if (self.peek() != .TOKEN_WHITESPACE and self.peek() != .TOKEN_COMMENT) {
            return false;
        }

        const saved_state = self.tokenizer.saveState();
        const saved_token = self.current_token;
        try self.skipWs();
        const matches = self.peek() == target;
        self.tokenizer.restoreState(saved_state);
        self.current_token = saved_token;
        return matches;
    }

    pub fn parse(self: *Parser) !CST {
        self.resetDiagnostics();
        const root = try self.makeNode(.NODE_ROOT, 0);
        errdefer root.deinit();

        // Consume leading trivia into root
        try self.consumeWs(root);

        const expr = try self.parseExpression(.LOWEST);
        try root.addChild(expr);

        // Consume trailing trivia, but NOT the final newline token
        while (self.peek() == .TOKEN_WHITESPACE or self.peek() == .TOKEN_COMMENT) {
            // Stop before whitespace that is just the final newline
            // Since tokenizer splits trailing newlines, check for single trailing \n at EOF
            if (self.peek() == .TOKEN_WHITESPACE and
                self.source.len > 0 and
                self.current_token.start >= self.source.len - 1 and
                self.source[self.source.len - 1] == '\n')
            {
                break;
            }
            const trivia = try self.consumeToken();
            try root.addChild(trivia);
        }

        // Root ends at source.len, excluding trailing newline if present
        const end_pos = if (self.source.len > 0 and self.source[self.source.len - 1] == '\n')
            self.source.len - 1
        else
            self.source.len;
        finishNode(root, end_pos);
        return CST.init(self.allocator, self.source, root);
    }

    /// Check if token can start a function application
    fn canApplyFunction(token: TokenKind) bool {
        return switch (token) {
            .TOKEN_IDENT,
            .TOKEN_OR,
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
    }

    /// Try to parse postfix operator with whitespace lookahead
    fn tryParsePostfixWithWhitespace(
        self: *Parser,
        left: *Node,
        min_prec: Precedence,
        postfix_count: *usize,
        postfix_limit: usize,
    ) ParseError!?*Node {
        if (self.peek() != .TOKEN_WHITESPACE) return null;

        const saved_state = self.tokenizer.saveState();
        const saved_token = self.current_token;
        try self.skipWs();
        const next_token = self.peek();
        self.tokenizer.restoreState(saved_state);
        self.current_token = saved_token;

        // Check for infix operator after whitespace
        if (getInfixPrecedence(next_token)) |op_prec| {
            if (@intFromEnum(op_prec) <= @intFromEnum(min_prec)) return null;
            const result = try self.parseBinaryOp(left, op_prec);
            try self.bumpPostfixCount(postfix_count, postfix_limit);
            return result;
        }

        // Check for has-attr (?) after whitespace
        if (next_token == .TOKEN_QUESTION) {
            if (@intFromEnum(Precedence.HAS_ATTR) <= @intFromEnum(min_prec)) return null;
            const result = try self.parseHasAttr(left);
            try self.bumpPostfixCount(postfix_count, postfix_limit);
            return result;
        }

        // Check for select (.) after whitespace
        if (next_token == .TOKEN_DOT) {
            if (@intFromEnum(Precedence.SELECT) <= @intFromEnum(min_prec)) return null;
            const result = try self.parseSelect(left);
            try self.bumpPostfixCount(postfix_count, postfix_limit);
            return result;
        }

        // Check for function application after whitespace
        if (canApplyFunction(next_token) and @intFromEnum(Precedence.CALL) > @intFromEnum(min_prec)) {
            const result = try self.parseFunctionApplication(left);
            try self.bumpPostfixCount(postfix_count, postfix_limit);
            return result;
        }

        return null;
    }

    /// Parse expression with Pratt parsing
    fn parseExpression(self: *Parser, min_prec: Precedence) ParseError!*Node {
        try self.skipWs();

        var left = try self.parsePrefix();
        const postfix_limit = @max(self.source.len, 1);
        var postfix_count: usize = 0;

        if (try self.tryParseInlineLambda(left)) |lambda_node| {
            return lambda_node;
        }

        while (true) {
            // Try parsing postfix with whitespace lookahead
            if (try self.tryParsePostfixWithWhitespace(left, min_prec, &postfix_count, postfix_limit)) |new_left| {
                left = new_left;
                continue;
            }

            // Check for infix binary operators (no whitespace)
            if (getInfixPrecedence(self.peek())) |op_prec| {
                if (@intFromEnum(op_prec) <= @intFromEnum(min_prec)) break;
                left = try self.parseBinaryOp(left, op_prec);
                try self.bumpPostfixCount(&postfix_count, postfix_limit);
                continue;
            }

            // Check for has-attr (?)
            if (self.peek() == .TOKEN_QUESTION) {
                if (@intFromEnum(Precedence.HAS_ATTR) <= @intFromEnum(min_prec)) break;
                left = try self.parseHasAttr(left);
                try self.bumpPostfixCount(&postfix_count, postfix_limit);
                continue;
            }

            // Check for select (.)
            if (self.peek() == .TOKEN_DOT) {
                if (@intFromEnum(Precedence.SELECT) <= @intFromEnum(min_prec)) break;
                left = try self.parseSelect(left);
                try self.bumpPostfixCount(&postfix_count, postfix_limit);
                continue;
            }

            // Check for function application (no whitespace)
            if (canApplyFunction(self.peek()) and @intFromEnum(Precedence.CALL) > @intFromEnum(min_prec)) {
                left = try self.parseFunctionApplication(left);
                try self.bumpPostfixCount(&postfix_count, postfix_limit);
                continue;
            }

            break;
        }

        return left;
    }

    fn resetDiagnostics(self: *Parser) void {
        if (self.diagnostics) |diag| diag.* = .{};
    }

    fn storeNote(diag: *Diagnostic, note: []const u8) void {
        const len = @min(note.len, diag.note_buf.len);
        std.mem.copyForwards(u8, diag.note_buf[0..len], note[0..len]);
        diag.note_len = len;
    }

    fn recordUnexpectedToken(self: *Parser, expected: TokenKind, note: []const u8) void {
        if (self.diagnostics) |diag| {
            diag.* = .{
                .kind = .unexpected_token,
                .span = .{ .start = self.current_token.start, .end = self.current_token.end },
                .got_token = self.current_token.kind,
                .expected_token = expected,
            };
            storeNote(diag, note);
        }
    }

    fn recordPostfixLimit(self: *Parser, limit: usize) void {
        if (self.diagnostics) |diag| {
            diag.* = .{
                .kind = .postfix_limit,
                .span = .{ .start = self.current_token.start, .end = self.current_token.end },
                .limit = limit,
            };
        }
    }

    fn recordInternal(self: *Parser, note: []const u8) void {
        if (self.diagnostics) |diag| {
            diag.* = .{
                .kind = .internal,
                .span = .{ .start = self.current_token.start, .end = self.current_token.end },
            };
            storeNote(diag, note);
        }
    }

    fn bumpPostfixCount(self: *Parser, counter: *usize, limit: usize) ParseError!void {
        counter.* += 1;
        if (counter.* > limit) {
            self.recordPostfixLimit(limit);
            return error.PostfixLimitExceeded;
        }
    }

    fn tryParseInlineLambda(self: *Parser, left: *Node) ParseError!?*Node {
        if (left.kind != .node or left.kind.node != .NODE_IDENT) {
            return null;
        }

        switch (self.peek()) {
            .TOKEN_COLON => return try self.buildSimpleLambda(left, false),
            .TOKEN_AT => return try self.buildBindLambda(left, false),
            .TOKEN_WHITESPACE, .TOKEN_COMMENT => {
                if (try self.peekAfterTrivia(.TOKEN_COLON)) {
                    return try self.buildSimpleLambda(left, true);
                }
                if (try self.peekAfterTrivia(.TOKEN_AT)) {
                    return try self.buildBindLambda(left, true);
                }
            },
            else => {},
        }

        return null;
    }

    fn buildSimpleLambda(self: *Parser, ident: *Node, consume_ws_before_colon: bool) ParseError!*Node {
        const lambda_node = try self.makeNode(.NODE_LAMBDA, ident.start);
        errdefer lambda_node.deinit();

        const param_node = try self.makeNode(.NODE_IDENT_PARAM, ident.start);
        errdefer param_node.deinit();
        try param_node.addChild(ident);
        finishNode(param_node, ident.end);
        try lambda_node.addChild(param_node);

        if (consume_ws_before_colon) {
            try self.consumeWs(lambda_node);
        }

        const colon = try self.expect(.TOKEN_COLON);
        try lambda_node.addChild(colon);
        try self.consumeWs(lambda_node);

        const body = try self.parseExpression(.LOWEST);
        try lambda_node.addChild(body);
        finishNode(lambda_node, body.end);
        return lambda_node;
    }

    fn buildBindLambda(self: *Parser, ident: *Node, consume_ws_before_at: bool) ParseError!*Node {
        const lambda_node = try self.makeNode(.NODE_LAMBDA, ident.start);
        errdefer lambda_node.deinit();

        const pattern_node = try self.makeNode(.NODE_PATTERN, ident.start);
        errdefer pattern_node.deinit();

        const bind_node = try self.makeNode(.NODE_PAT_BIND, ident.start);
        errdefer bind_node.deinit();

        try bind_node.addChild(ident);
        if (consume_ws_before_at) {
            try self.consumeWs(bind_node);
        }
        const at = try self.expect(.TOKEN_AT);
        try bind_node.addChild(at);
        finishNode(bind_node, at.end);

        try pattern_node.addChild(bind_node);
        try self.consumeWs(pattern_node);

        var pattern_end = bind_node.end;
        if (self.peek() == .TOKEN_L_BRACE) {
            const lbrace = try self.consumeToken();
            try pattern_node.addChild(lbrace);
            try self.consumeWs(pattern_node);

            const entries_end = try self.parsePatternEntries(pattern_node);
            if (self.peek() == .TOKEN_R_BRACE) {
                const rbrace = try self.consumeToken();
                try pattern_node.addChild(rbrace);
                pattern_end = rbrace.end;
            } else {
                pattern_end = entries_end;
            }
        }

        try self.consumeWs(pattern_node);
        try self.detectDoubleBindAfterPattern(pattern_node);
        if (pattern_node.end > pattern_end) {
            pattern_end = pattern_node.end;
        }
        finishNode(pattern_node, pattern_end);

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

    const ParseError = error{ OutOfMemory, UnexpectedToken, PostfixLimitExceeded };

    fn parsePrefix(self: *Parser) ParseError!*Node {
        const start = self.current_token.start;

        return switch (self.peek()) {
            .TOKEN_INTEGER, .TOKEN_FLOAT, .TOKEN_URI, .TOKEN_PATH => try self.parseLiteral(),
            .TOKEN_IDENT, .TOKEN_OR => try self.parseIdent(), // "or" can be used as identifier
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

        // Paths get their own node type and may have interpolation
        if (self.peek() == .TOKEN_PATH) {
            const node = try self.makeNode(.NODE_PATH, start);
            errdefer node.deinit();

            // Consume initial path token
            const path_tok = try self.consumeToken();
            try node.addChild(path_tok);

            // Loop consuming path continuations and interpolations
            while (self.peek() == .TOKEN_INTERPOL_START) {
                // Parse interpolation: ${ expr }
                const interp_node = try self.makeNode(.NODE_INTERPOL, self.current_token.start);
                errdefer interp_node.deinit();

                const interp_start = try self.consumeToken();
                try interp_node.addChild(interp_start);

                const expr = try self.parseExpression(.LOWEST);
                try interp_node.addChild(expr);

                const interp_end = try self.expect(.TOKEN_INTERPOL_END);
                try interp_node.addChild(interp_end);

                finishNode(interp_node, interp_end.end);
                try node.addChild(interp_node);

                // Check for path continuation after interpolation
                if (self.peek() == .TOKEN_PATH) {
                    const cont_tok = try self.consumeToken();
                    try node.addChild(cont_tok);
                } else {
                    // No more path tokens
                    break;
                }
            }

            finishNode(node, node.children.items[node.children.items.len - 1].end);
            return node;
        } else {
            // Other literals (integers, floats, URIs)
            const node = try self.makeNode(.NODE_LITERAL, start);
            const tok = try self.consumeToken();
            try node.addChild(tok);
            finishNode(node, tok.end);
            return node;
        }
    }

    fn parseIdent(self: *Parser) ParseError!*Node {
        const start = self.current_token.start;
        const node = try self.makeNode(.NODE_IDENT, start);
        // TOKEN_OR can be used as identifier - convert to TOKEN_IDENT
        const token_kind = if (self.current_token.kind == .TOKEN_OR) .TOKEN_IDENT else self.current_token.kind;
        const tok = try self.makeToken(token_kind, self.current_token.start, self.current_token.end);
        try self.advance();
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

                    // Consume whitespace after ${
                    try self.consumeWs(interp_node);

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
                    self.recordUnexpectedToken(.TOKEN_STRING_END, "unterminated string literal");

                    const error_node = try self.makeNode(.NODE_ERROR, self.current_token.start);
                    errdefer error_node.deinit();

                    if (self.peek() != .TOKEN_EOF) {
                        const unexpected = try self.consumeToken();
                        try error_node.addChild(unexpected);
                        finishNode(error_node, unexpected.end);
                    } else {
                        finishNode(error_node, self.current_token.start);
                    }

                    try node.addChild(error_node);
                    finishNode(node, error_node.end);
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
        //
        // NOTE: Deprecated Nix behavior not supported (and intentionally so):
        // Legacy Nix allowed expressions like "foo foldl or false" to parse as
        // ((foo (foldl or)) false), with exactly ONE level of function application
        // nesting in arguments. Our implementation uses strict left-associativity:
        // (((foo foldl) or) false), which matches the future Nix behavior.
        //
        // Nix itself warns: "This expression uses `or` as an identifier in a way that
        // will change in a future Nix release. Wrap this entire expression in parentheses
        // to preserve its current meaning: (foldl or)"
        // See: https://github.com/NixOS/nix/pull/11121
        //
        // This affects the or-as-ident test from rnix-parser, which tests the deprecated
        // behavior. Our parser implements the correct future behavior instead.
        const arg = try self.parseExpression(.CALL);
        try node.addChild(arg);

        finishNode(node, arg.end);
        return node;
    }

    /// Parse a single attribute in a select path (ident, string, or dynamic)
    fn parseSelectAttribute(self: *Parser) ParseError!?*Node {
        if (self.peek() == .TOKEN_IDENT or self.peek() == .TOKEN_OR) {
            return try self.parseIdent();
        } else if (self.peek() == .TOKEN_STRING_START or self.peek() == .TOKEN_L_BRACE) {
            return try self.parsePrefix();
        } else if (self.peek() == .TOKEN_INTERPOL_START) {
            const dyn_node = try self.makeNode(.NODE_DYNAMIC, self.current_token.start);
            errdefer dyn_node.deinit();

            const interp_start = try self.expect(.TOKEN_INTERPOL_START);
            try dyn_node.addChild(interp_start);

            const expr = try self.parseExpression(.LOWEST);
            try dyn_node.addChild(expr);

            const interp_end = try self.expect(.TOKEN_INTERPOL_END);
            try dyn_node.addChild(interp_end);

            finishNode(dyn_node, interp_end.end);
            return dyn_node;
        }
        return null;
    }

    /// Try to parse 'or' default value for select expression
    fn tryParseSelectOrDefault(self: *Parser, node: *Node) ParseError!void {
        if (self.peek() != .TOKEN_WHITESPACE) return;

        const saved_state = self.tokenizer.saveState();
        const saved_token = self.current_token;
        try self.skipWs();

        if (self.peek() == .TOKEN_OR) {
            self.tokenizer.restoreState(saved_state);
            self.current_token = saved_token;
            try self.consumeWs(node);

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

    fn parseSelect(self: *Parser, left: *Node) ParseError!*Node {
        const start = left.start;
        const node = try self.makeNode(.NODE_SELECT, start);
        errdefer node.deinit();

        try node.addChild(left);
        try self.consumeWs(node);

        const dot = try self.expect(.TOKEN_DOT);
        try node.addChild(dot);

        const attrpath_start = self.current_token.start;
        const attrpath = try self.makeNode(.NODE_ATTRPATH, attrpath_start);
        errdefer attrpath.deinit();

        var last_end: usize = dot.end;

        // Parse first attribute
        if (try self.parseSelectAttribute()) |attr| {
            try attrpath.addChild(attr);
            last_end = attr.end;
        } else {
            attrpath.deinit();
            finishNode(node, dot.end);
            return node;
        }

        // Parse additional .attr parts
        while (self.peek() == .TOKEN_DOT) {
            const next_dot = try self.consumeToken();
            try attrpath.addChild(next_dot);
            last_end = next_dot.end;

            if (try self.parseSelectAttribute()) |attr| {
                try attrpath.addChild(attr);
                last_end = attr.end;
            } else {
                break;
            }
        }

        finishNode(attrpath, last_end);
        try node.addChild(attrpath);
        finishNode(node, last_end);

        try self.tryParseSelectOrDefault(node);

        return node;
    }

    fn parseHasAttr(self: *Parser, left: *Node) ParseError!*Node {
        const start = left.start;
        const node = try self.makeNode(.NODE_HAS_ATTR, start);
        errdefer node.deinit();

        try node.addChild(left);
        try self.consumeWs(node);

        const question = try self.expect(.TOKEN_QUESTION);
        try node.addChild(question);
        try self.consumeWs(node);

        // Parse attribute path
        const attrpath_start = self.current_token.start;
        const attrpath = try self.makeNode(.NODE_ATTRPATH, attrpath_start);
        errdefer attrpath.deinit();

        // Parse the attribute (identifier, string, or dynamic)
        if (self.peek() == .TOKEN_IDENT or self.peek() == .TOKEN_OR) {
            const attr = try self.parseIdent();
            try attrpath.addChild(attr);
            finishNode(attrpath, attr.end);
        } else if (self.peek() == .TOKEN_STRING_START) {
            const attr = try self.parseString();
            try attrpath.addChild(attr);
            finishNode(attrpath, attr.end);
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
            try attrpath.addChild(dyn_node);
            finishNode(attrpath, dyn_node.end);
        } else {
            attrpath.deinit();
            finishNode(node, question.end);
            return node;
        }

        try node.addChild(attrpath);
        finishNode(node, attrpath.end);

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

        // Parse pattern or identifier parameter
        // Always call parsePattern, it will handle identifiers and pattern binds
        if (self.peek() == .TOKEN_L_BRACE or self.peek() == .TOKEN_L_PAREN or self.peek() == .TOKEN_IDENT) {
            const pattern = try self.parsePattern();
            try node.addChild(pattern);
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
        return switch (self.peek()) {
            .TOKEN_L_BRACE => try self.parsePatternFromBraces(),
            .TOKEN_IDENT, .TOKEN_OR => try self.parsePatternFromIdent(),
            else => try self.makeNode(.NODE_PATTERN, self.current_token.start),
        };
    }

    fn parsePatternFromBraces(self: *Parser) ParseError!*Node {
        const start = self.current_token.start;
        const node = try self.makeNode(.NODE_PATTERN, start);
        errdefer node.deinit();

        const lbrace = try self.consumeToken();
        try node.addChild(lbrace);
        try self.consumeWs(node);

        const last_entry_end = try self.parsePatternEntries(node);

        if (self.peek() == .TOKEN_R_BRACE) {
            const rbrace = try self.consumeToken();
            try node.addChild(rbrace);
            finishNode(node, rbrace.end);
        } else {
            finishNode(node, last_entry_end);
        }

        try self.consumeWs(node);
        if (self.peek() == .TOKEN_AT) {
            try self.parsePatternRightBind(node);
            try self.consumeWs(node);
        }
        try self.detectDoubleBindAfterPattern(node);

        return node;
    }

    fn parsePatternFromIdent(self: *Parser) ParseError!*Node {
        const ident = try self.parseIdent();

        if (self.peek() == .TOKEN_AT or try self.peekAfterTrivia(.TOKEN_AT)) {
            const bind_node = try self.makeNode(.NODE_PAT_BIND, ident.start);
            errdefer bind_node.deinit();

            try bind_node.addChild(ident);
            if (self.peek() != .TOKEN_AT) {
                try self.consumeWs(bind_node);
            }

            const at = try self.expect(.TOKEN_AT);
            try bind_node.addChild(at);
            try self.consumeWs(bind_node);

            const pattern = try self.parsePattern();
            try bind_node.addChild(pattern);
            finishNode(bind_node, pattern.end);

            try self.consumeWs(bind_node);
            try self.detectDoubleBindAfterPattern(bind_node);
            return bind_node;
        }

        return ident;
    }

    fn parsePatternRightBind(self: *Parser, node: *Node) ParseError!void {
        const bind_start = self.current_token.start;
        const at_node = try self.makeNode(.NODE_PAT_BIND, bind_start);
        errdefer at_node.deinit();

        const at = try self.consumeToken();
        try at_node.addChild(at);
        try self.consumeWs(at_node);

        const ident = try self.parseIdent();
        try at_node.addChild(ident);
        finishNode(at_node, ident.end);

        try node.addChild(at_node);
        finishNode(node, at_node.end);
    }

    fn detectDoubleBindAfterPattern(self: *Parser, node: *Node) ParseError!void {
        if (self.peek() == .TOKEN_AT) {
            var end_pos = node.end;
            try self.addDoubleBindError(node, &end_pos);
            finishNode(node, end_pos);
            return;
        }

        if (self.peek() == .TOKEN_WHITESPACE or self.peek() == .TOKEN_COMMENT) {
            const saved_state = self.tokenizer.saveState();
            const saved_token = self.current_token;
            try self.skipWs();
            if (self.peek() == .TOKEN_AT) {
                self.tokenizer.restoreState(saved_state);
                self.current_token = saved_token;
                try self.consumeWs(node);

                var end_pos = node.end;
                try self.addDoubleBindError(node, &end_pos);
                finishNode(node, end_pos);
            } else {
                self.tokenizer.restoreState(saved_state);
                self.current_token = saved_token;
            }
        }
    }

    fn addDoubleBindError(self: *Parser, node: *Node, end_out: *usize) ParseError!void {
        const error_node = try self.makeNode(.NODE_ERROR, self.current_token.start);
        errdefer error_node.deinit();

        const at = try self.consumeToken();
        try error_node.addChild(at);
        try self.consumeWs(error_node);

        if (self.peek() == .TOKEN_IDENT or self.peek() == .TOKEN_OR) {
            const ident = try self.parseIdent();
            try error_node.addChild(ident);
            finishNode(error_node, ident.end);
            end_out.* = ident.end;
        } else {
            finishNode(error_node, at.end);
            end_out.* = at.end;
        }

        try node.addChild(error_node);
    }

    fn parsePatternEntries(self: *Parser, container: *Node) ParseError!usize {
        var last_end = container.start;

        while (self.peek() != .TOKEN_R_BRACE and self.peek() != .TOKEN_EOF) {
            if (self.peek() == .TOKEN_ELLIPSIS) {
                const ellipsis = try self.consumeToken();
                try container.addChild(ellipsis);
                last_end = ellipsis.end;
                try self.consumeWs(container);
                break;
            }

            const entry = try self.parsePatternEntry();
            last_end = entry.end;
            try container.addChild(entry);
            try self.consumeWs(container);

            if (self.peek() == .TOKEN_COMMA) {
                const comma = try self.consumeToken();
                try container.addChild(comma);
                last_end = comma.end;
                try self.consumeWs(container);
            } else {
                break;
            }
        }

        return last_end;
    }

    fn parsePatternEntry(self: *Parser) ParseError!*Node {
        const entry_start = self.current_token.start;
        const entry = try self.makeNode(.NODE_PAT_ENTRY, entry_start);
        errdefer entry.deinit();

        const name = try self.parseIdent();
        try entry.addChild(name);
        var end_pos = name.end;

        var has_default = false;
        if (self.peek() == .TOKEN_QUESTION) {
            has_default = true;
        } else if (try self.peekAfterTrivia(.TOKEN_QUESTION)) {
            try self.consumeWs(entry);
            has_default = true;
        }

        if (has_default) {
            const question = try self.expect(.TOKEN_QUESTION);
            try entry.addChild(question);
            try self.consumeWs(entry);

            const default_expr = try self.parseExpression(.LOWEST);
            try entry.addChild(default_expr);
            end_pos = default_expr.end;
        }

        finishNode(entry, end_pos);
        return entry;
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

    /// Parse legacy let syntax: let { bindings }
    fn parseLegacyLet(self: *Parser, start: usize, let_tok: *Node, ws_tokens: std.ArrayList(*Node)) ParseError!*Node {
        const node = try self.makeNode(.NODE_LEGACY_LET, start);
        errdefer node.deinit();

        try node.addChild(let_tok);
        for (ws_tokens.items) |ws| {
            try node.addChild(ws);
        }

        const lbrace = try self.expect(.TOKEN_L_BRACE);
        try node.addChild(lbrace);

        while (true) {
            try self.consumeWs(node);
            if (self.peek() == .TOKEN_R_BRACE or self.peek() == .TOKEN_EOF) break;

            if (self.peek() == .TOKEN_INHERIT) {
                const inherit_node = try self.parseInherit();
                try node.addChild(inherit_node);
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

    /// Parse modern let-in syntax: let bindings in expr
    fn parseModernLetIn(self: *Parser, start: usize, let_tok: *Node, ws_tokens: std.ArrayList(*Node)) ParseError!*Node {
        const node = try self.makeNode(.NODE_LET_IN, start);
        errdefer node.deinit();

        try node.addChild(let_tok);
        for (ws_tokens.items) |ws| {
            try node.addChild(ws);
        }

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

    fn parseLetIn(self: *Parser) ParseError!*Node {
        const start = self.current_token.start;
        const let_tok = try self.expect(.TOKEN_LET);

        var ws_tokens = std.ArrayList(*Node){};
        defer ws_tokens.deinit(self.allocator);
        while (self.peek() == .TOKEN_WHITESPACE or self.peek() == .TOKEN_COMMENT) {
            const ws = try self.consumeToken();
            try ws_tokens.append(self.allocator, ws);
        }

        const is_legacy = self.peek() == .TOKEN_L_BRACE;
        if (is_legacy) {
            return try self.parseLegacyLet(start, let_tok, ws_tokens);
        } else {
            return try self.parseModernLetIn(start, let_tok, ws_tokens);
        }
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
        try self.consumeWs(node);

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

    /// Parse inherit source: (expr)
    fn parseInheritFrom(self: *Parser) ParseError!*Node {
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
        return from_node;
    }

    fn parseInherit(self: *Parser) ParseError!*Node {
        const start = self.current_token.start;
        const node = try self.makeNode(.NODE_INHERIT, start);
        errdefer node.deinit();

        const inherit_tok = try self.expect(.TOKEN_INHERIT);
        try node.addChild(inherit_tok);
        try self.consumeWs(node);

        if (self.peek() == .TOKEN_L_PAREN) {
            const from_node = try self.parseInheritFrom();
            try node.addChild(from_node);
            try self.consumeWs(node);
        }

        // Parse inherited attributes (identifiers, strings, or dynamic)
        while (self.peek() == .TOKEN_IDENT or self.peek() == .TOKEN_OR or self.peek() == .TOKEN_STRING_START or self.peek() == .TOKEN_INTERPOL_START) {
            if (self.peek() == .TOKEN_IDENT or self.peek() == .TOKEN_OR) {
                const ident = try self.parseIdent();
                try node.addChild(ident);
            } else if (self.peek() == .TOKEN_STRING_START) {
                const str = try self.parseString();
                try node.addChild(str);
            } else if (self.peek() == .TOKEN_INTERPOL_START) {
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

        try self.consumeWs(node);

        if (self.peek() == .TOKEN_ASSIGN) {
            const assign = try self.consumeToken();
            try node.addChild(assign);
        }

        try self.consumeWs(node);

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
            if (self.peek() == .TOKEN_IDENT or self.peek() == .TOKEN_OR) {
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
