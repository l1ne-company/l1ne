const std = @import("std");
const parser = @import("parser.zig");

pub const deserialize = @import("deserialize.zig");

/// A single key-value pair in a CCL configuration
pub const KeyValue = struct {
    key: []const u8,
    value: Value,

    pub fn deinit(self: *KeyValue, allocator: std.mem.Allocator) void {
        switch (self.value) {
            .string => {},
            .nested => |*config| config.deinit(allocator),
        }
    }
};

/// CCL value types: either a string or a nested configuration
pub const Value = union(enum) {
    string: []const u8,
    nested: Config,
};

/// A CCL configuration - a list of key-value pairs
pub const Config = struct {
    pairs: std.ArrayList(KeyValue),

    pub fn init() Config {
        return .{
            .pairs = std.ArrayList(KeyValue){},
        };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.pairs.items) |*pair| {
            pair.deinit(allocator);
        }
        self.pairs.deinit(allocator);
    }

    /// Get a value by key
    pub fn get(self: *const Config, key: []const u8) ?*const Value {
        for (self.pairs.items) |*pair| {
            if (std.mem.eql(u8, pair.key, key)) {
                return &pair.value;
            }
        }
        return null;
    }

    /// Get all values for a given key (useful for lists with empty keys)
    pub fn getAll(self: *const Config, key: []const u8, allocator: std.mem.Allocator) !std.ArrayList(*const Value) {
        var result = std.ArrayList(*const Value){};
        for (self.pairs.items) |*pair| {
            if (std.mem.eql(u8, pair.key, key)) {
                try result.append(allocator, &pair.value);
            }
        }
        return result;
    }
};

/// Parse CCL from a string
pub fn parse(allocator: std.mem.Allocator, input: []const u8) !Config {
    return parser.parse(allocator, input);
}

test "basic import" {
    _ = parser;
}
