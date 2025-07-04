const std = @import("std");

const cli = @import("cli.zig");

pub fn main() !void {

    var arena = std.heapArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var arg_iterator = try std.process.argsWithAllocator(allocator);
    defer arg_iterator.deinit();
}
