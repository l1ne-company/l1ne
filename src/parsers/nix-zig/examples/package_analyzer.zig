const std = @import("std");
const nix = @import("../root.zig");
const ast = @import("../ast.zig");

/// A complex example that analyzes a Nix package definition
/// and extracts structured metadata, dependencies, and build information
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Complex Nix package definition
    const source =
        \\{ lib, stdenv, fetchFromGitHub, pkg-config, openssl, zlib }:
        \\
        \\stdenv.mkDerivation rec {
        \\  pname = "myapp";
        \\  version = "2.1.0";
        \\
        \\  src = fetchFromGitHub {
        \\    owner = "myorg";
        \\    repo = pname;
        \\    rev = "v${version}";
        \\    sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        \\  };
        \\
        \\  nativeBuildInputs = [ pkg-config ];
        \\  buildInputs = [ openssl zlib ];
        \\
        \\  configureFlags = [
        \\    "--enable-ssl"
        \\    "--with-zlib=${zlib}"
        \\  ];
        \\
        \\  meta = with lib; {
        \\    description = "A sample application";
        \\    homepage = "https://example.com/${pname}";
        \\    license = licenses.mit;
        \\    maintainers = with maintainers; [ alice bob ];
        \\    platforms = platforms.unix;
        \\  };
        \\}
    ;

    var analyzer = PackageAnalyzer.init(allocator);
    defer analyzer.deinit();

    std.debug.print("=== Analyzing Nix Package ===\n\n", .{});

    var cst = try nix.parse(allocator, source);
    defer cst.deinit();

    try analyzer.analyze(&cst, cst.root);

    // Print analysis results
    try analyzer.printReport();
}

const PackageInfo = struct {
    pname: ?[]const u8 = null,
    version: ?[]const u8 = null,
    description: ?[]const u8 = null,
    homepage: ?[]const u8 = null,
    license: ?[]const u8 = null,

    build_inputs: std.ArrayList([]const u8),
    native_build_inputs: std.ArrayList([]const u8),
    configure_flags: std.ArrayList([]const u8),
    maintainers: std.ArrayList([]const u8),

    function_params: std.ArrayList([]const u8),
    interpolations: std.ArrayList(InterpolationInfo),

    has_rec_attrset: bool = false,
    uses_with: std.ArrayList([]const u8),

    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) PackageInfo {
        return .{
            .build_inputs = std.ArrayList([]const u8).init(allocator),
            .native_build_inputs = std.ArrayList([]const u8).init(allocator),
            .configure_flags = std.ArrayList([]const u8).init(allocator),
            .maintainers = std.ArrayList([]const u8).init(allocator),
            .function_params = std.ArrayList([]const u8).init(allocator),
            .interpolations = std.ArrayList(InterpolationInfo).init(allocator),
            .uses_with = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *PackageInfo) void {
        self.build_inputs.deinit();
        self.native_build_inputs.deinit();
        self.configure_flags.deinit();
        self.maintainers.deinit();
        self.function_params.deinit();
        self.interpolations.deinit();
        self.uses_with.deinit();
    }
};

const InterpolationInfo = struct {
    location: []const u8,
    expression: []const u8,
    context: []const u8, // "string" or "path"
};

const PackageAnalyzer = struct {
    info: PackageInfo,
    cst: ?*const ast.CST = null,
    current_attribute_path: std.ArrayList([]const u8),

    fn init(allocator: std.mem.Allocator) PackageAnalyzer {
        return .{
            .info = PackageInfo.init(allocator),
            .current_attribute_path = std.ArrayList([]const u8).init(allocator),
        };
    }

    fn deinit(self: *PackageAnalyzer) void {
        self.info.deinit();
        self.current_attribute_path.deinit();
    }

    fn analyze(self: *PackageAnalyzer, cst: *const ast.CST, node: *const ast.Node) !void {
        self.cst = cst;
        try self.analyzeNode(node);
    }

    fn analyzeNode(self: *PackageAnalyzer, node: *const ast.Node) !void {
        switch (node.kind) {
            .node => |kind| {
                switch (kind) {
                    .NODE_LAMBDA => {
                        try self.analyzeLambda(node);
                    },
                    .NODE_ATTR_SET => {
                        try self.analyzeAttrSet(node);
                    },
                    .NODE_ATTRPATH_VALUE => {
                        try self.analyzeAttrPathValue(node);
                    },
                    .NODE_INTERPOL => {
                        try self.analyzeInterpolation(node);
                    },
                    .NODE_WITH => {
                        try self.analyzeWith(node);
                    },
                    .NODE_REC_ATTR_SET => {
                        self.info.has_rec_attrset = true;
                    },
                    else => {},
                }
            },
            .token => {},
        }

        // Recurse into children
        for (node.children.items) |child| {
            try self.analyzeNode(child);
        }
    }

    fn analyzeLambda(self: *PackageAnalyzer, node: *const ast.Node) !void {
        // Extract function parameters from lambda
        for (node.children.items) |child| {
            if (child.kind == .node) {
                switch (child.kind.node) {
                    .NODE_PATTERN => {
                        try self.extractPatternParams(child);
                    },
                    .NODE_IDENT_PARAM => {
                        // Simple parameter
                        for (child.children.items) |ident_child| {
                            if (ident_child.kind == .node and ident_child.kind.node == .NODE_IDENT) {
                                const param_name = self.cst.?.getText(ident_child);
                                try self.info.function_params.append(param_name);
                            }
                        }
                    },
                    else => {},
                }
            }
        }
    }

    fn extractPatternParams(self: *PackageAnalyzer, pattern_node: *const ast.Node) !void {
        for (pattern_node.children.items) |child| {
            if (child.kind == .node and child.kind.node == .NODE_PATTERN_ENTRY) {
                // Find the identifier in the pattern entry
                for (child.children.items) |entry_child| {
                    if (entry_child.kind == .node and entry_child.kind.node == .NODE_IDENT) {
                        const param_name = self.cst.?.getText(entry_child);
                        try self.info.function_params.append(param_name);
                        break;
                    }
                }
            }
        }
    }

    fn analyzeAttrSet(self: *PackageAnalyzer, _: *const ast.Node) !void {
        // Could track nesting depth or attribute set types here
    }

    fn analyzeAttrPathValue(self: *PackageAnalyzer, node: *const ast.Node) !void {
        var attr_name: ?[]const u8 = null;
        var value_node: ?*const ast.Node = null;

        // Extract attribute name and value
        for (node.children.items) |child| {
            if (child.kind == .node and child.kind.node == .NODE_ATTRPATH) {
                attr_name = try self.extractAttrPath(child);
            }
        }

        // Find the value after '='
        var found_assign = false;
        for (node.children.items) |child| {
            if (found_assign and child.kind != .token) {
                value_node = child;
                break;
            }
            if (child.kind == .token and child.kind.token == .TOKEN_ASSIGN) {
                found_assign = true;
            }
        }

        if (attr_name == null or value_node == null) return;

        const name = attr_name.?;
        const value = value_node.?;

        // Match known attributes
        if (std.mem.eql(u8, name, "pname")) {
            self.info.pname = try self.extractStringValue(value);
        } else if (std.mem.eql(u8, name, "version")) {
            self.info.version = try self.extractStringValue(value);
        } else if (std.mem.eql(u8, name, "description")) {
            self.info.description = try self.extractStringValue(value);
        } else if (std.mem.eql(u8, name, "homepage")) {
            self.info.homepage = try self.extractStringValue(value);
        } else if (std.mem.eql(u8, name, "license")) {
            self.info.license = self.cst.?.getText(value);
        } else if (std.mem.eql(u8, name, "buildInputs")) {
            try self.extractListItems(value, &self.info.build_inputs);
        } else if (std.mem.eql(u8, name, "nativeBuildInputs")) {
            try self.extractListItems(value, &self.info.native_build_inputs);
        } else if (std.mem.eql(u8, name, "configureFlags")) {
            try self.extractListItems(value, &self.info.configure_flags);
        } else if (std.mem.eql(u8, name, "maintainers")) {
            try self.extractListItems(value, &self.info.maintainers);
        }
    }

    fn extractAttrPath(self: *PackageAnalyzer, attrpath_node: *const ast.Node) ![]const u8 {
        for (attrpath_node.children.items) |child| {
            if (child.kind == .node and child.kind.node == .NODE_IDENT) {
                return self.cst.?.getText(child);
            }
        }
        return "";
    }

    fn extractStringValue(self: *PackageAnalyzer, node: *const ast.Node) !?[]const u8 {
        if (node.kind == .node and node.kind.node == .NODE_STRING) {
            // Extract string content (skip quotes)
            for (node.children.items) |child| {
                if (child.kind == .token and child.kind.token == .TOKEN_STRING_CONTENT) {
                    return self.cst.?.getText(child);
                }
            }
        }
        return null;
    }

    fn extractListItems(self: *PackageAnalyzer, node: *const ast.Node, list: *std.ArrayList([]const u8)) !void {
        if (node.kind == .node and node.kind.node == .NODE_LIST) {
            try self.extractListItemsRecursive(node, list);
        } else if (node.kind == .node and node.kind.node == .NODE_APPLY) {
            // Handle `with maintainers; [ ... ]` pattern
            try self.extractListItemsRecursive(node, list);
        }
    }

    fn extractListItemsRecursive(self: *PackageAnalyzer, node: *const ast.Node, list: *std.ArrayList([]const u8)) !void {
        for (node.children.items) |child| {
            switch (child.kind) {
                .node => |kind| {
                    switch (kind) {
                        .NODE_IDENT => {
                            const item = self.cst.?.getText(child);
                            try list.append(item);
                        },
                        .NODE_STRING => {
                            if (try self.extractStringValue(child)) |str_val| {
                                try list.append(str_val);
                            }
                        },
                        .NODE_LIST => {
                            try self.extractListItemsRecursive(child, list);
                        },
                        else => {
                            try self.extractListItemsRecursive(child, list);
                        },
                    }
                },
                .token => {},
            }
        }
    }

    fn analyzeInterpolation(self: *PackageAnalyzer, node: *const ast.Node) !void {
        var expr_text: []const u8 = "";

        // Extract the expression inside ${}
        for (node.children.items) |child| {
            if (child.kind != .token or
                (child.kind.token != .TOKEN_INTERPOL_START and
                child.kind.token != .TOKEN_INTERPOL_END))
            {
                expr_text = self.cst.?.getText(child);
                break;
            }
        }

        // Determine context (string or path)
        const context = if (self.isInPath(node)) "path" else "string";

        const location = try std.fmt.allocPrint(
            self.info.allocator,
            "{}..{}",
            .{ node.start, node.end },
        );

        try self.info.interpolations.append(.{
            .location = location,
            .expression = expr_text,
            .context = context,
        });
    }

    fn isInPath(self: *PackageAnalyzer, node: *const ast.Node) bool {
        // Walk up to find if we're inside NODE_PATH
        // (Simplified - in real implementation, would need parent tracking)
        _ = self;
        _ = node;
        return false; // Simplified for this example
    }

    fn analyzeWith(self: *PackageAnalyzer, node: *const ast.Node) !void {
        // Extract what we're "with"-ing
        for (node.children.items) |child| {
            if (child.kind == .node and child.kind.node == .NODE_IDENT) {
                const with_scope = self.cst.?.getText(child);
                try self.info.uses_with.append(with_scope);
                break;
            } else if (child.kind == .node and child.kind.node == .NODE_SELECT) {
                const with_scope = self.cst.?.getText(child);
                try self.info.uses_with.append(with_scope);
                break;
            }
        }
    }

    fn printReport(self: *PackageAnalyzer) !void {
        const stdout = std.io.getStdOut().writer();

        try stdout.writeAll("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
        try stdout.writeAll("  PACKAGE ANALYSIS REPORT\n");
        try stdout.writeAll("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n");

        // Basic metadata
        try stdout.writeAll("📦 PACKAGE METADATA\n");
        try stdout.writeAll("─────────────────────\n");
        if (self.info.pname) |pname| {
            try stdout.print("  Name:        {s}\n", .{pname});
        }
        if (self.info.version) |version| {
            try stdout.print("  Version:     {s}\n", .{version});
        }
        if (self.info.description) |desc| {
            try stdout.print("  Description: {s}\n", .{desc});
        }
        if (self.info.homepage) |homepage| {
            try stdout.print("  Homepage:    {s}\n", .{homepage});
        }
        if (self.info.license) |license| {
            try stdout.print("  License:     {s}\n", .{license});
        }
        try stdout.writeAll("\n");

        // Function signature
        if (self.info.function_params.items.len > 0) {
            try stdout.writeAll("🔧 FUNCTION PARAMETERS\n");
            try stdout.writeAll("─────────────────────\n");
            for (self.info.function_params.items) |param| {
                try stdout.print("  • {s}\n", .{param});
            }
            try stdout.writeAll("\n");
        }

        // Dependencies
        if (self.info.native_build_inputs.items.len > 0) {
            try stdout.writeAll("⚙️  NATIVE BUILD INPUTS\n");
            try stdout.writeAll("─────────────────────\n");
            for (self.info.native_build_inputs.items) |dep| {
                try stdout.print("  • {s}\n", .{dep});
            }
            try stdout.writeAll("\n");
        }

        if (self.info.build_inputs.items.len > 0) {
            try stdout.writeAll("📚 BUILD INPUTS\n");
            try stdout.writeAll("─────────────────────\n");
            for (self.info.build_inputs.items) |dep| {
                try stdout.print("  • {s}\n", .{dep});
            }
            try stdout.writeAll("\n");
        }

        // Configure flags
        if (self.info.configure_flags.items.len > 0) {
            try stdout.writeAll("🔨 CONFIGURE FLAGS\n");
            try stdout.writeAll("─────────────────────\n");
            for (self.info.configure_flags.items) |flag| {
                try stdout.print("  • {s}\n", .{flag});
            }
            try stdout.writeAll("\n");
        }

        // Maintainers
        if (self.info.maintainers.items.len > 0) {
            try stdout.writeAll("👥 MAINTAINERS\n");
            try stdout.writeAll("─────────────────────\n");
            for (self.info.maintainers.items) |maintainer| {
                try stdout.print("  • {s}\n", .{maintainer});
            }
            try stdout.writeAll("\n");
        }

        // Interpolations
        if (self.info.interpolations.items.len > 0) {
            try stdout.writeAll("🔗 INTERPOLATIONS\n");
            try stdout.writeAll("─────────────────────\n");
            for (self.info.interpolations.items) |interp| {
                try stdout.print("  • {s} @ {s}: ${{{s}}}\n", .{
                    interp.context,
                    interp.location,
                    interp.expression,
                });
            }
            try stdout.writeAll("\n");
        }

        // With statements
        if (self.info.uses_with.items.len > 0) {
            try stdout.writeAll("🌐 WITH SCOPES\n");
            try stdout.writeAll("─────────────────────\n");
            for (self.info.uses_with.items) |scope| {
                try stdout.print("  • {s}\n", .{scope});
            }
            try stdout.writeAll("\n");
        }

        // Analysis summary
        try stdout.writeAll("📊 ANALYSIS SUMMARY\n");
        try stdout.writeAll("─────────────────────\n");
        try stdout.print("  Parameters:       {}\n", .{self.info.function_params.items.len});
        try stdout.print("  Dependencies:     {}\n", .{
            self.info.native_build_inputs.items.len + self.info.build_inputs.items.len,
        });
        try stdout.print("  Interpolations:   {}\n", .{self.info.interpolations.items.len});
        try stdout.print("  Uses 'rec':       {s}\n", .{if (self.info.has_rec_attrset) "Yes" else "No"});
        try stdout.print("  With statements:  {}\n", .{self.info.uses_with.items.len});

        try stdout.writeAll("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
    }
};
