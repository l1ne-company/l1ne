//! SIMD-optimized character set matching for the Nix tokenizer.
//!
//! Provides both scalar and vectorized character classification functions
//! for maximum performance. The vectorized functions process 16-32 bytes
//! at once on modern CPUs.
//!
//! Design follows TigerStyle:
//! - Explicit, simple functions with primitive arguments
//! - Comptime character set definitions
//! - Both scalar and vector paths for safety
//! - All functions are inline-able hot paths

const std = @import("std");

/// Whitespace characters: space, tab, newline, carriage return
pub const WhitespaceSet = struct {
    pub inline fn match(ch: u8) bool {
        return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
    }

    pub inline fn matchVector(chunk: anytype) @TypeOf(chunk == chunk) {
        const Vec = @TypeOf(chunk);
        const space: Vec = @splat(' ');
        const tab: Vec = @splat('\t');
        const nl: Vec = @splat('\n');
        const cr: Vec = @splat('\r');

        return (chunk == space) or (chunk == tab) or (chunk == nl) or (chunk == cr);
    }
};

/// Decimal digits: 0-9
pub const DigitSet = struct {
    pub inline fn match(ch: u8) bool {
        return ch >= '0' and ch <= '9';
    }

    pub inline fn matchVector(chunk: anytype) @TypeOf(chunk >= chunk) {
        const Vec = @TypeOf(chunk);
        const zero: Vec = @splat('0');
        const nine: Vec = @splat('9');
        return (chunk >= zero) & (chunk <= nine);
    }
};

/// Identifier start characters: A-Z, a-z, _
pub const IdentStartSet = struct {
    pub inline fn match(ch: u8) bool {
        return std.ascii.isAlphabetic(ch) or ch == '_';
    }

    pub inline fn matchVector(chunk: anytype) @TypeOf(chunk == chunk) {
        const Vec = @TypeOf(chunk);
        const upper_a: Vec = @splat('A');
        const upper_z: Vec = @splat('Z');
        const lower_a: Vec = @splat('a');
        const lower_z: Vec = @splat('z');
        const underscore: Vec = @splat('_');

        const is_upper = (chunk >= upper_a) & (chunk <= upper_z);
        const is_lower = (chunk >= lower_a) & (chunk <= lower_z);
        const is_underscore = (chunk == underscore);

        return is_upper | is_lower | is_underscore;
    }
};

/// Identifier continuation characters: A-Z, a-z, 0-9, _, -, '
pub const IdentContSet = struct {
    pub inline fn match(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '\'';
    }

    pub inline fn matchVector(chunk: anytype) @TypeOf(chunk == chunk) {
        const Vec = @TypeOf(chunk);

        // Alphanumeric ranges
        const is_digit = DigitSet.matchVector(chunk);
        const upper_a: Vec = @splat('A');
        const upper_z: Vec = @splat('Z');
        const lower_a: Vec = @splat('a');
        const lower_z: Vec = @splat('z');

        const is_upper = (chunk >= upper_a) & (chunk <= upper_z);
        const is_lower = (chunk >= lower_a) & (chunk <= lower_z);

        // Special characters for identifiers
        const underscore: Vec = @splat('_');
        const dash: Vec = @splat('-');
        const apostrophe: Vec = @splat('\'');

        const is_special = (chunk == underscore) | (chunk == dash) | (chunk == apostrophe);

        return is_digit | is_upper | is_lower | is_special;
    }
};

/// Path-terminating characters (whitespace, delimiters, operators)
pub const PathTerminatorSet = struct {
    pub inline fn match(ch: u8) bool {
        return WhitespaceSet.match(ch) or
            ch == ';' or ch == ')' or ch == ']' or ch == '}' or ch == ':';
    }

    pub inline fn matchVector(chunk: anytype) @TypeOf(chunk == chunk) {
        const Vec = @TypeOf(chunk);

        const is_ws = WhitespaceSet.matchVector(chunk);
        const semicolon: Vec = @splat(';');
        const rparen: Vec = @splat(')');
        const rbrack: Vec = @splat(']');
        const rbrace: Vec = @splat('}');
        const colon: Vec = @splat(':');

        return is_ws | (chunk == semicolon) | (chunk == rparen) |
            (chunk == rbrack) | (chunk == rbrace) | (chunk == colon);
    }
};

test "charset: whitespace" {
    try std.testing.expect(WhitespaceSet.match(' '));
    try std.testing.expect(WhitespaceSet.match('\t'));
    try std.testing.expect(WhitespaceSet.match('\n'));
    try std.testing.expect(WhitespaceSet.match('\r'));
    try std.testing.expect(!WhitespaceSet.match('a'));
    try std.testing.expect(!WhitespaceSet.match('0'));
}

test "charset: digits" {
    try std.testing.expect(DigitSet.match('0'));
    try std.testing.expect(DigitSet.match('5'));
    try std.testing.expect(DigitSet.match('9'));
    try std.testing.expect(!DigitSet.match('a'));
    try std.testing.expect(!DigitSet.match(' '));
}

test "charset: identifier start" {
    try std.testing.expect(IdentStartSet.match('a'));
    try std.testing.expect(IdentStartSet.match('Z'));
    try std.testing.expect(IdentStartSet.match('_'));
    try std.testing.expect(!IdentStartSet.match('0'));
    try std.testing.expect(!IdentStartSet.match('-'));
}

test "charset: identifier continuation" {
    try std.testing.expect(IdentContSet.match('a'));
    try std.testing.expect(IdentContSet.match('Z'));
    try std.testing.expect(IdentContSet.match('0'));
    try std.testing.expect(IdentContSet.match('_'));
    try std.testing.expect(IdentContSet.match('-'));
    try std.testing.expect(IdentContSet.match('\''));
    try std.testing.expect(!IdentContSet.match(' '));
    try std.testing.expect(!IdentContSet.match(';'));
}

test "charset: path terminators" {
    try std.testing.expect(PathTerminatorSet.match(' '));
    try std.testing.expect(PathTerminatorSet.match(';'));
    try std.testing.expect(PathTerminatorSet.match(')'));
    try std.testing.expect(PathTerminatorSet.match(']'));
    try std.testing.expect(PathTerminatorSet.match('}'));
    try std.testing.expect(PathTerminatorSet.match(':'));
    try std.testing.expect(!PathTerminatorSet.match('a'));
    try std.testing.expect(!PathTerminatorSet.match('/'));
}

test "charset: SIMD vector matching" {
    const len = std.simd.suggestVectorLength(u8) orelse return error.SkipZigTest;
    const Vec = @Vector(len, u8);

    // Test whitespace vector matching
    const ws_vec: Vec = @splat(' ');
    try std.testing.expect(@reduce(.And, WhitespaceSet.matchVector(ws_vec)));

    // Test digit vector matching
    const digit_vec: Vec = @splat('5');
    try std.testing.expect(@reduce(.And, DigitSet.matchVector(digit_vec)));

    // Test mixed vector (should have some matches, some non-matches)
    var mixed: [32]u8 = undefined;
    for (&mixed, 0..) |*ch, i| {
        ch.* = if (i % 2 == 0) ' ' else 'x';
    }
    const mixed_vec: Vec = mixed[0..len].*;
    const ws_matches = WhitespaceSet.matchVector(mixed_vec);
    try std.testing.expect(@reduce(.Or, ws_matches)); // Some matches
    try std.testing.expect(!@reduce(.And, ws_matches)); // But not all
}
