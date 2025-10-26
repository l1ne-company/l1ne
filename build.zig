const std = @import("std");
const builtin = @import("builtin");

const zig_version = std.SemanticVersion{
    .major = 0,
    .minor = 15,
    .patch = 1,
};

// use zig 0.15.1
comptime {
    const zig_version_eq = zig_version.major == builtin.zig_version.major and
        zig_version.minor == builtin.zig_version.minor and
        (zig_version.patch == builtin.zig_version.patch);
    if (!zig_version_eq) {
        @compileError(std.fmt.comptimePrint(
            "unsupported zig version: expected {any}, found {any}",
            .{ zig_version, builtin.zig_version },
        ));
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // CCL library module
    const ccl_module = b.addModule("ccl", .{
        .root_source_file = b.path("src/ccl-zig/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "l1ne",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/l1ne/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add CCL module to executable
    exe.root_module.addImport("ccl", ccl_module);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // CCL example executable
    const ccl_example = b.addExecutable(.{
        .name = "ccl-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ccl-zig/examples/example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add CCL module to example
    ccl_example.root_module.addImport("ccl", ccl_module);

    // Optionally install the example
    const install_example = b.step("install-ccl-example", "Install CCL example binary");
    install_example.dependOn(&b.addInstallArtifact(ccl_example, .{}).step);

    const example_step = b.step("ccl-example", "Run CCL example");
    const example_run = b.addRunArtifact(ccl_example);
    example_step.dependOn(&example_run.step);

    // CCL reflection demo
    const ccl_reflection_demo = b.addExecutable(.{
        .name = "ccl-reflection-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ccl-zig/examples/reflection-demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    ccl_reflection_demo.root_module.addImport("ccl", ccl_module);

    const reflection_demo_step = b.step("ccl-reflection-demo", "Run CCL reflection demo");
    const reflection_demo_run = b.addRunArtifact(ccl_reflection_demo);
    reflection_demo_step.dependOn(&reflection_demo_run.step);

    // CCL timeline demo
    const ccl_timeline_demo = b.addExecutable(.{
        .name = "ccl-timeline-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ccl-zig/examples/timeline-demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    ccl_timeline_demo.root_module.addImport("ccl", ccl_module);

    const timeline_demo_step = b.step("ccl-timeline-demo", "Run CCL timeline demo (compile-time vs runtime)");
    const timeline_demo_run = b.addRunArtifact(ccl_timeline_demo);
    timeline_demo_step.dependOn(&timeline_demo_run.step);

    // CCL tests
    const ccl_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ccl-zig/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const ccl_deserialize_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ccl-zig/deserialize.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const ccl_example_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ccl-zig/examples/example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add CCL module to example tests
    ccl_example_tests.root_module.addImport("ccl", ccl_module);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(ccl_tests).step);
    test_step.dependOn(&b.addRunArtifact(ccl_deserialize_tests).step);
    test_step.dependOn(&b.addRunArtifact(ccl_example_tests).step);
}
