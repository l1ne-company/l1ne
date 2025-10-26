const std = @import("std");
const root = @import("root.zig");
const Config = root.Config;
const Value = root.Value;

pub const DeserializeError = error{
    MissingField,
    TypeMismatch,
    InvalidFormat,
    OutOfMemory,
};

/// Deserialize a CCL Config into a Zig type using comptime reflection
pub fn deserialize(comptime T: type, allocator: std.mem.Allocator, config: *const Config) !T {
    const type_info = @typeInfo(T);

    switch (type_info) {
        .@"struct" => return deserializeStruct(T, allocator, config),
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice) {
                // Handle slices (arrays/lists)
                return deserializeSlice(T, allocator, config);
            }
            return DeserializeError.TypeMismatch;
        },
        .optional => |opt_info| {
            return deserializeOptional(opt_info.child, allocator, config);
        },
        else => return DeserializeError.TypeMismatch,
    }
}

fn deserializeStruct(comptime T: type, allocator: std.mem.Allocator, config: *const Config) !T {
    var result: T = undefined;
    const fields = @typeInfo(T).@"struct".fields;

    inline for (fields) |field| {
        const value_opt = config.get(field.name);

        if (value_opt) |value| {
            @field(result, field.name) = try deserializeValue(field.type, allocator, value);
        } else {
            // Field not found - check if it has a default value
            if (field.defaultValue()) |default_val| {
                @field(result, field.name) = default_val;
            } else if (@typeInfo(field.type) == .optional) {
                @field(result, field.name) = null;
            } else {
                return DeserializeError.MissingField;
            }
        }
    }

    return result;
}

fn deserializeSlice(comptime T: type, allocator: std.mem.Allocator, config: *const Config) !T {
    const ptr_info = @typeInfo(T).pointer;
    const Child = ptr_info.child;

    // Get all values with empty key (list items)
    var values = try config.getAll("", allocator);
    defer values.deinit(allocator);

    var result = try allocator.alloc(Child, values.items.len);
    errdefer allocator.free(result);

    for (values.items, 0..) |value, i| {
        result[i] = try deserializeValue(Child, allocator, value);
    }

    return result;
}

fn deserializeOptional(comptime T: type, allocator: std.mem.Allocator, config: *const Config) !?T {
    return try deserialize(T, allocator, config);
}

fn deserializeValue(comptime T: type, allocator: std.mem.Allocator, value: *const Value) !T {
    switch (value.*) {
        .string => |str| return deserializeFromString(T, str),
        .nested => |*nested_config| return try deserialize(T, allocator, nested_config),
    }
}

fn deserializeFromString(comptime T: type, str: []const u8) !T {
    const type_info = @typeInfo(T);

    switch (type_info) {
        .int => return std.fmt.parseInt(T, str, 10) catch DeserializeError.InvalidFormat,
        .float => return std.fmt.parseFloat(T, str) catch DeserializeError.InvalidFormat,
        .bool => {
            if (std.mem.eql(u8, str, "true")) return true;
            if (std.mem.eql(u8, str, "false")) return false;
            return DeserializeError.InvalidFormat;
        },
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                // String type
                return str;
            }
            return DeserializeError.TypeMismatch;
        },
        .@"enum" => {
            return std.meta.stringToEnum(T, str) orelse DeserializeError.InvalidFormat;
        },
        else => return DeserializeError.TypeMismatch,
    }
}

/// Convenience function to parse and deserialize in one call
pub fn parseInto(comptime T: type, allocator: std.mem.Allocator, input: []const u8) !T {
    var config = try root.parse(allocator, input);
    defer config.deinit(allocator);

    return try deserialize(T, allocator, &config);
}

test "deserialize simple struct" {
    const allocator = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const input =
        \\name = Alice
        \\age = 30
    ;

    const person = try parseInto(Person, allocator, input);

    try std.testing.expectEqualStrings("Alice", person.name);
    try std.testing.expectEqual(@as(u32, 30), person.age);
}

test "deserialize nested struct" {
    const allocator = std.testing.allocator;

    const Address = struct {
        city: []const u8,
        zip: u32,
    };

    const Person = struct {
        name: []const u8,
        address: Address,
    };

    const input =
        \\name = Bob
        \\address =
        \\  city = NYC
        \\  zip = 10001
    ;

    const person = try parseInto(Person, allocator, input);

    try std.testing.expectEqualStrings("Bob", person.name);
    try std.testing.expectEqualStrings("NYC", person.address.city);
    try std.testing.expectEqual(@as(u32, 10001), person.address.zip);
}

test "deserialize with optional fields" {
    const allocator = std.testing.allocator;

    const Person = struct {
        name: []const u8,
        age: ?u32 = null,
    };

    const input =
        \\name = Charlie
    ;

    const person = try parseInto(Person, allocator, input);

    try std.testing.expectEqualStrings("Charlie", person.name);
    try std.testing.expectEqual(@as(?u32, null), person.age);
}

test "deserialize boolean" {
    const allocator = std.testing.allocator;

    const TestConfig = struct {
        enabled: bool,
    };

    const input =
        \\enabled = true
    ;

    const cfg = try parseInto(TestConfig, allocator, input);
    try std.testing.expectEqual(true, cfg.enabled);
}

test "deserialize enum" {
    const allocator = std.testing.allocator;

    const LogLevel = enum {
        debug,
        info,
        warn,
        @"error",
    };

    const TestConfig = struct {
        level: LogLevel,
    };

    const input =
        \\level = info
    ;

    const cfg = try parseInto(TestConfig, allocator, input);
    try std.testing.expectEqual(LogLevel.info, cfg.level);
}
