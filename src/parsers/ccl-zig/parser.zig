//! CCL parser with inline tests. Run `zig test src/parsers/ccl-zig/parser.zig`
//! or `zig test src/parsers/ccl-zig/root.zig` from the monorepo root to execute
//! them in isolation.

const std = @import("std");
const root = @import("root.zig");
const Config = root.Config;
const KeyValue = root.KeyValue;
const Value = root.Value;

const ParseError = error{
    InvalidSyntax,
    UnexpectedIndentation,
    OutOfMemory,
};

const Line = struct {
    content: []const u8,
    indent: usize,
    line_num: usize,
};

/// Main parser entry point
pub fn parse(allocator: std.mem.Allocator, input: []const u8) !Config {
    var config = Config.init();
    errdefer config.deinit(allocator);

    var lines = std.mem.splitScalar(u8, input, '\n');
    var line_num: usize = 0;

    while (lines.next()) |raw_line| {
        line_num += 1;
        const line = parseLine(raw_line, line_num);

        // Skip empty lines and comments
        if (line.content.len == 0 or isComment(line.content)) {
            continue;
        }

        try parseKeyValue(allocator, &config, line, &lines, &line_num);
    }

    return config;
}

fn parseLine(raw: []const u8, line_num: usize) Line {
    const indent = countIndent(raw);
    const content = std.mem.trim(u8, raw, &std.ascii.whitespace);

    return .{
        .content = content,
        .indent = indent,
        .line_num = line_num,
    };
}

fn countIndent(line: []const u8) usize {
    var count: usize = 0;
    for (line) |ch| {
        if (ch == ' ') {
            count += 1;
        } else if (ch == '\t') {
            count += 4; // Treat tab as 4 spaces
        } else {
            break;
        }
    }
    return count;
}

fn isComment(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "/=");
}

fn parseKeyValue(
    allocator: std.mem.Allocator,
    config: *Config,
    line: Line,
    lines: *std.mem.SplitIterator(u8, .scalar),
    line_num: *usize,
) !void {
    // Find the '=' separator
    const eq_pos = std.mem.indexOf(u8, line.content, "=") orelse {
        return ParseError.InvalidSyntax;
    };

    const key = std.mem.trim(u8, line.content[0..eq_pos], &std.ascii.whitespace);
    const value_str = std.mem.trim(u8, line.content[eq_pos + 1 ..], &std.ascii.whitespace);

    // Check if value is empty (indicates nested config follows)
    if (value_str.len == 0) {
        // Next lines should be indented - parse nested config
        var nested = Config.init();
        errdefer nested.deinit(allocator);

        const base_indent = line.indent;

        // Peek ahead to parse nested lines
        while (lines.next()) |next_raw| {
            line_num.* += 1;
            const next_line = parseLine(next_raw, line_num.*);

            // Skip empty lines and comments
            if (next_line.content.len == 0 or isComment(next_line.content)) {
                continue;
            }

            // If indentation decreased, we're done with nested section
            if (next_line.indent <= base_indent) {
                // Put line back by re-parsing it at the parent level
                // This is a bit tricky in Zig - we need to handle this line
                // For now, we'll just stop (could improve with buffering)
                break;
            }

            // Parse nested key-value
            try parseKeyValue(allocator, &nested, next_line, lines, line_num);
        }

        try config.pairs.append(allocator, .{
            .key = key,
            .value = .{ .nested = nested },
        });
    } else {
        // Simple string value
        try config.pairs.append(allocator, .{
            .key = key,
            .value = .{ .string = value_str },
        });
    }
}

test "parse simple key-value" {
    const allocator = std.testing.allocator;

    const input =
        \\name = John
        \\age = 30
    ;

    var config = try parse(allocator, input);
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), config.pairs.items.len);
    try std.testing.expectEqualStrings("name", config.pairs.items[0].key);
    try std.testing.expectEqualStrings("John", config.pairs.items[0].value.string);
}

test "parse with comments" {
    const allocator = std.testing.allocator;

    const input =
        \\/= This is a comment
        \\name = Alice
        \\/= Another comment
        \\city = NYC
    ;

    var config = try parse(allocator, input);
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), config.pairs.items.len);
}

test "parse list items" {
    const allocator = std.testing.allocator;

    const input =
        \\= apple
        \\= banana
        \\= orange
    ;

    var config = try parse(allocator, input);
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), config.pairs.items.len);
    for (config.pairs.items) |pair| {
        try std.testing.expectEqualStrings("", pair.key);
    }
}
