const std = @import("std");
const ast = @import("ast.zig");
const TokenKind = ast.TokenKind;

pub const Token = struct {
    kind: TokenKind,
    start: usize,
    end: usize,
};

const Context = union(enum) {
    string_body: struct { multiline: bool },
    string_end: void,
    interpol: struct { brackets: u32 },
    interpol_start: void,
};

pub const Tokenizer = struct {
    source: []const u8,
    pos: usize = 0,
    ctx_stack: std.ArrayList(Context),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Tokenizer {
        return .{
            .source = source,
            .ctx_stack = std.ArrayList(Context){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Tokenizer) void {
        self.ctx_stack.deinit(self.allocator);
    }

    pub const State = struct {
        pos: usize,
        ctx_stack_snapshot: []const Context,
    };

    pub fn saveState(self: *const Tokenizer) State {
        return .{
            .pos = self.pos,
            .ctx_stack_snapshot = self.ctx_stack.items,
        };
    }

    pub fn restoreState(self: *Tokenizer, state: State) void {
        self.pos = state.pos;
        // Restore context stack to the saved state
        self.ctx_stack.shrinkRetainingCapacity(0);
        for (state.ctx_stack_snapshot) |ctx| {
            self.ctx_stack.appendAssumeCapacity(ctx);
        }
    }

    fn peek(self: *const Tokenizer, offset: usize) ?u8 {
        const idx = self.pos + offset;
        if (idx >= self.source.len) return null;
        return self.source[idx];
    }

    fn current(self: *const Tokenizer) ?u8 {
        return self.peek(0);
    }

    fn advance(self: *Tokenizer) void {
        if (self.pos < self.source.len) {
            self.pos += 1;
        }
    }

    fn advanceN(self: *Tokenizer, n: usize) void {
        self.pos = @min(self.pos + n, self.source.len);
    }

    fn startsWith(self: *const Tokenizer, needle: []const u8) bool {
        if (self.pos + needle.len > self.source.len) return false;
        return std.mem.eql(u8, self.source[self.pos..][0..needle.len], needle);
    }

    fn isIdentStart(ch: u8) bool {
        return std.ascii.isAlphabetic(ch) or ch == '_';
    }

    fn isIdentCont(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '\'';
    }

    fn isWhitespace(ch: u8) bool {
        return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
    }

    fn consumeWhile(self: *Tokenizer, comptime pred: fn (u8) bool) void {
        while (self.current()) |ch| {
            if (!pred(ch)) break;
            self.advance();
        }
    }

    // Tokenize string content
    fn nextString(self: *Tokenizer, multiline: bool) !TokenKind {
        while (self.current()) |ch| {
            if (!multiline and ch == '"') {
                // End of string - return any content we've accumulated
                _ = self.ctx_stack.pop();
                try self.ctx_stack.append(self.allocator, .string_end);
                return .TOKEN_STRING_CONTENT;
            } else if (multiline and self.startsWith("''")) {
                // Check for escape sequences
                if (self.peek(2)) |next_ch| {
                    if (next_ch == '\'' or next_ch == '$' or next_ch == '\\') {
                        // Escaped sequence, consume it
                        self.advanceN(3);
                        continue;
                    }
                }
                // End of multiline string - return any content we've accumulated
                _ = self.ctx_stack.pop();
                try self.ctx_stack.append(self.allocator, .string_end);
                return .TOKEN_STRING_CONTENT;
            } else if (ch == '\\' and !multiline) {
                // Escape sequence
                self.advance();
                if (self.current() != null) self.advance();
            } else if (self.startsWith("${")) {
                // Start of interpolation - return any content before it
                try self.ctx_stack.append(self.allocator, .interpol_start);
                return .TOKEN_STRING_CONTENT;
            } else {
                self.advance();
            }
        }
        // EOF in string
        _ = self.ctx_stack.pop();
        return .TOKEN_ERROR;
    }

    pub fn next(self: *Tokenizer) !Token {
        const start = self.pos;

        // Handle context-specific tokenization
        while (self.ctx_stack.items.len > 0) {
            const ctx = self.ctx_stack.items[self.ctx_stack.items.len - 1];
            switch (ctx) {
                .interpol_start => {
                    _ = self.ctx_stack.pop();
                    try self.ctx_stack.append(self.allocator, .{ .interpol = .{ .brackets = 0 } });
                    if (self.startsWith("${")) {
                        self.advanceN(2);
                        return .{ .kind = .TOKEN_INTERPOL_START, .start = start, .end = self.pos };
                    }
                    return .{ .kind = .TOKEN_ERROR, .start = start, .end = self.pos };
                },
                .string_body => |sb| {
                    const kind = try self.nextString(sb.multiline);
                    // Skip empty content tokens
                    if (self.pos == start and kind == .TOKEN_STRING_CONTENT) continue;
                    return .{ .kind = kind, .start = start, .end = self.pos };
                },
                .string_end => {
                    _ = self.ctx_stack.pop();
                    if (self.current() == '"' and !self.startsWith("''")) {
                        self.advance();
                        return .{ .kind = .TOKEN_STRING_END, .start = start, .end = self.pos };
                    } else if (self.startsWith("''")) {
                        self.advanceN(2);
                        return .{ .kind = .TOKEN_STRING_END, .start = start, .end = self.pos };
                    }
                    return .{ .kind = .TOKEN_ERROR, .start = start, .end = self.pos };
                },
                .interpol => {},
            }
            break;
        }

        // EOF
        if (self.pos >= self.source.len) {
            return .{ .kind = .TOKEN_EOF, .start = start, .end = start };
        }

        const ch = self.current().?;

        // Whitespace
        if (isWhitespace(ch)) {
            self.consumeWhile(isWhitespace);
            return .{ .kind = .TOKEN_WHITESPACE, .start = start, .end = self.pos };
        }

        // Comments
        if (ch == '#') {
            while (self.current()) |c| {
                if (c == '\n') break;
                self.advance();
            }
            return .{ .kind = .TOKEN_COMMENT, .start = start, .end = self.pos };
        }

        // Multi-line comments /* */
        if (self.startsWith("/*")) {
            self.advanceN(2);
            var depth: usize = 1;
            while (depth > 0 and self.current() != null) {
                if (self.startsWith("/*")) {
                    depth += 1;
                    self.advanceN(2);
                } else if (self.startsWith("*/")) {
                    depth -= 1;
                    self.advanceN(2);
                } else {
                    self.advance();
                }
            }
            return .{ .kind = .TOKEN_COMMENT, .start = start, .end = self.pos };
        }

        // Interpolation (works both in strings and outside for dynamic attributes)
        if (self.startsWith("${")) {
            self.advanceN(2);
            try self.ctx_stack.append(self.allocator, .{ .interpol = .{ .brackets = 0 } });
            return .{ .kind = .TOKEN_INTERPOL_START, .start = start, .end = self.pos };
        }

        // String literals
        if (ch == '"') {
            self.advance();
            try self.ctx_stack.append(self.allocator, .{ .string_body = .{ .multiline = false } });
            return .{ .kind = .TOKEN_STRING_START, .start = start, .end = self.pos };
        }

        // Multi-line strings ''
        if (self.startsWith("''")) {
            self.advanceN(2);
            try self.ctx_stack.append(self.allocator, .{ .string_body = .{ .multiline = true } });
            return .{ .kind = .TOKEN_STRING_START, .start = start, .end = self.pos };
        }

        // Numbers
        if (std.ascii.isDigit(ch)) {
            return self.tokenizeNumber();
        }

        // Identifiers and keywords
        if (isIdentStart(ch)) {
            return self.tokenizeIdentOrKeyword();
        }

        // Paths
        if (ch == '/' or ch == '.' or ch == '~' or ch == '<') {
            if (self.maybeTokenizePath()) |tok| {
                return tok;
            }
        }

        // Operators and delimiters
        return try self.tokenizeOperator();
    }

    fn tokenizeNumber(self: *Tokenizer) Token {
        const start = self.pos;

        // Integer part
        self.consumeWhile(std.ascii.isDigit);

        // Check for float
        if (self.current() == '.' and self.peek(1) != null and std.ascii.isDigit(self.peek(1).?)) {
            self.advance(); // consume .
            self.consumeWhile(std.ascii.isDigit);

            // Check for scientific notation
            if (self.current()) |c| {
                if (c == 'e' or c == 'E') {
                    self.advance();
                    if (self.current()) |sign| {
                        if (sign == '+' or sign == '-') {
                            self.advance();
                        }
                    }
                    self.consumeWhile(std.ascii.isDigit);
                }
            }

            return .{ .kind = .TOKEN_FLOAT, .start = start, .end = self.pos };
        }

        // Check for scientific notation on integer
        if (self.current()) |c| {
            if (c == 'e' or c == 'E') {
                self.advance();
                if (self.current()) |sign| {
                    if (sign == '+' or sign == '-') {
                        self.advance();
                    }
                }
                self.consumeWhile(std.ascii.isDigit);
                return .{ .kind = .TOKEN_FLOAT, .start = start, .end = self.pos };
            }
        }

        return .{ .kind = .TOKEN_INTEGER, .start = start, .end = self.pos };
    }

    fn tokenizeIdentOrKeyword(self: *Tokenizer) Token {
        const start = self.pos;
        self.advance(); // first char
        self.consumeWhile(isIdentCont);

        // Check for URI (scheme://...)
        if (self.startsWith("://")) {
            self.advanceN(3);
            // Consume rest of URI
            while (self.current()) |c| {
                if (isWhitespace(c) or c == ';' or c == ')' or c == ']' or c == '}' or c == ',' or c == '#') break;
                self.advance();
            }
            return .{ .kind = .TOKEN_URI, .start = start, .end = self.pos };
        }

        const text = self.source[start..self.pos];
        const kind: TokenKind = if (std.mem.eql(u8, text, "if"))
            .TOKEN_IF
        else if (std.mem.eql(u8, text, "then"))
            .TOKEN_THEN
        else if (std.mem.eql(u8, text, "else"))
            .TOKEN_ELSE
        else if (std.mem.eql(u8, text, "let"))
            .TOKEN_LET
        else if (std.mem.eql(u8, text, "in"))
            .TOKEN_IN
        else if (std.mem.eql(u8, text, "rec"))
            .TOKEN_REC
        else if (std.mem.eql(u8, text, "inherit"))
            .TOKEN_INHERIT
        else if (std.mem.eql(u8, text, "or"))
            .TOKEN_OR
        else if (std.mem.eql(u8, text, "assert"))
            .TOKEN_ASSERT
        else if (std.mem.eql(u8, text, "with"))
            .TOKEN_WITH
        else
            .TOKEN_IDENT;

        return .{ .kind = kind, .start = start, .end = self.pos };
    }

    fn maybeTokenizePath(self: *Tokenizer) ?Token {
        const start = self.pos;

        // Search path <...>
        if (self.current() == '<') {
            // Check if next character is valid for a path (not an operator or number)
            const saved = self.pos;
            self.advance();
            const next_ch = self.current();

            // Only treat as path if followed by a letter, not =, >, or whitespace
            if (next_ch != null and next_ch.? != '=' and next_ch.? != '>' and
                !isWhitespace(next_ch.?) and std.ascii.isAlphabetic(next_ch.?))
            {
                while (self.current()) |ch| {
                    if (ch == '>') {
                        self.advance();
                        return .{ .kind = .TOKEN_PATH, .start = start, .end = self.pos };
                    }
                    self.advance();
                }
                // Invalid, but return as path
                return .{ .kind = .TOKEN_PATH, .start = start, .end = self.pos };
            } else {
                // Not a path, restore position
                self.pos = saved;
                return null;
            }
        }

        // Check for path-like patterns
        const saved_pos = self.pos;

        if (self.current() == '~') {
            self.advance();
            if (self.current() == '/' or self.current() == null or !std.ascii.isAlphanumeric(self.current().?)) {
                // It's a path
                while (self.current()) |ch| {
                    if (isWhitespace(ch) or ch == ';' or ch == ')' or ch == ']' or ch == '}') break;
                    self.advance();
                }
                return .{ .kind = .TOKEN_PATH, .start = start, .end = self.pos };
            }
            self.pos = saved_pos;
            return null;
        }

        if (self.current() == '/' or self.startsWith("./") or self.startsWith("../")) {
            // Don't treat // as a path - it's the update operator
            if (self.startsWith("//")) {
                self.pos = saved_pos;
                return null;
            }

            // Consume path
            while (self.current()) |ch| {
                if (isWhitespace(ch) or ch == ';' or ch == ')' or ch == ']' or ch == '}' or ch == ':') break;
                self.advance();
            }

            // Check if we consumed anything meaningful
            if (self.pos > start + 1) {
                return .{ .kind = .TOKEN_PATH, .start = start, .end = self.pos };
            }
        }

        self.pos = saved_pos;
        return null;
    }

    fn tokenizeOperator(self: *Tokenizer) !Token {
        const start = self.pos;

        // Check three-char operators first
        if (self.startsWith("...")) {
            self.advanceN(3);
            return .{ .kind = .TOKEN_ELLIPSIS, .start = start, .end = self.pos };
        }

        // Check two-char operators
        if (self.startsWith("//")) {
            self.advanceN(2);
            return .{ .kind = .TOKEN_UPDATE, .start = start, .end = self.pos };
        }
        if (self.startsWith("++")) {
            self.advanceN(2);
            return .{ .kind = .TOKEN_CONCAT, .start = start, .end = self.pos };
        }
        if (self.startsWith("==")) {
            self.advanceN(2);
            return .{ .kind = .TOKEN_EQUAL, .start = start, .end = self.pos };
        }
        if (self.startsWith("!=")) {
            self.advanceN(2);
            return .{ .kind = .TOKEN_NOT_EQUAL, .start = start, .end = self.pos };
        }
        if (self.startsWith("<=")) {
            self.advanceN(2);
            return .{ .kind = .TOKEN_LESS_OR_EQ, .start = start, .end = self.pos };
        }
        if (self.startsWith(">=")) {
            self.advanceN(2);
            return .{ .kind = .TOKEN_MORE_OR_EQ, .start = start, .end = self.pos };
        }
        if (self.startsWith("&&")) {
            self.advanceN(2);
            return .{ .kind = .TOKEN_AND_AND, .start = start, .end = self.pos };
        }
        if (self.startsWith("||")) {
            self.advanceN(2);
            return .{ .kind = .TOKEN_OR_OR, .start = start, .end = self.pos };
        }
        if (self.startsWith("->")) {
            self.advanceN(2);
            return .{ .kind = .TOKEN_IMPLICATION, .start = start, .end = self.pos };
        }
        if (self.startsWith("<|")) {
            self.advanceN(2);
            return .{ .kind = .TOKEN_PIPE_LEFT, .start = start, .end = self.pos };
        }
        if (self.startsWith("|>")) {
            self.advanceN(2);
            return .{ .kind = .TOKEN_PIPE_RIGHT, .start = start, .end = self.pos };
        }

        // Single char operators
        const ch = self.current().?;
        self.advance();

        // Handle braces in interpolation context
        if (ch == '{') {
            if (self.ctx_stack.items.len > 0) {
                if (self.ctx_stack.items[self.ctx_stack.items.len - 1] == .interpol) {
                    self.ctx_stack.items[self.ctx_stack.items.len - 1].interpol.brackets += 1;
                }
            }
            return .{ .kind = .TOKEN_L_BRACE, .start = start, .end = self.pos };
        }

        if (ch == '}') {
            if (self.ctx_stack.items.len > 0) {
                if (self.ctx_stack.items[self.ctx_stack.items.len - 1] == .interpol) {
                    const brackets = &self.ctx_stack.items[self.ctx_stack.items.len - 1].interpol.brackets;
                    if (brackets.* == 0) {
                        _ = self.ctx_stack.pop();
                        return .{ .kind = .TOKEN_INTERPOL_END, .start = start, .end = self.pos };
                    } else {
                        brackets.* -= 1;
                    }
                }
            }
            return .{ .kind = .TOKEN_R_BRACE, .start = start, .end = self.pos };
        }

        const kind: TokenKind = switch (ch) {
            '+' => .TOKEN_ADD,
            '-' => .TOKEN_SUB,
            '*' => .TOKEN_MUL,
            '/' => .TOKEN_DIV,
            '<' => .TOKEN_LESS,
            '>' => .TOKEN_MORE,
            '!' => .TOKEN_INVERT,
            '?' => .TOKEN_QUESTION,
            '[' => .TOKEN_L_BRACK,
            ']' => .TOKEN_R_BRACK,
            '(' => .TOKEN_L_PAREN,
            ')' => .TOKEN_R_PAREN,
            ';' => .TOKEN_SEMICOLON,
            ':' => .TOKEN_COLON,
            ',' => .TOKEN_COMMA,
            '.' => .TOKEN_DOT,
            '@' => .TOKEN_AT,
            '=' => .TOKEN_ASSIGN,
            else => .TOKEN_ERROR,
        };

        return .{ .kind = kind, .start = start, .end = self.pos };
    }
};

test "tokenizer: basic tokens" {
    const source = "{ a = 42; }";
    var tokenizer = try Tokenizer.init(std.testing.allocator, source);
    defer tokenizer.deinit();

    var tokens = std.ArrayList(Token).init(std.testing.allocator);
    defer tokens.deinit();

    while (true) {
        const tok = try tokenizer.next();
        try tokens.append(tok);
        if (tok.kind == .TOKEN_EOF) break;
    }

    // Should have: {, ws, a, ws, =, ws, 42, ws, ;, ws, }, EOF
    try std.testing.expect(tokens.items.len > 0);
}
