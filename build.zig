const std = @import("std");
const builtin = @import("builtin");

const zig_version = std.SemanticVersion{
    .major = 0,
    .minor = 15,
    .patch = 1,
};

// use zig 0.15.x (allow patch version differences)
comptime {
    const zig_version_compatible = zig_version.major == builtin.zig_version.major and
        zig_version.minor == builtin.zig_version.minor;
    if (!zig_version_compatible) {
        @compileError(std.fmt.comptimePrint(
            "unsupported zig version: expected 0.15.x, found {any}",
            .{builtin.zig_version},
        ));
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Nix parser module
    const nix_module = b.addModule("nix", .{
        .root_source_file = b.path("src/parsers/nix-zig/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // CCL parser module
    const ccl_module = b.addModule("ccl", .{
        .root_source_file = b.path("src/parsers/ccl-zig/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // L1NE main executable
    const l1ne_exe = b.addExecutable(.{
        .name = "l1ne",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/l1ne/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add module dependencies to l1ne
    l1ne_exe.root_module.addImport("nix", nix_module);
    l1ne_exe.root_module.addImport("ccl", ccl_module);

    b.installArtifact(l1ne_exe);

    const run_step = b.step("run", "Run l1ne");
    const run_cmd = b.addRunArtifact(l1ne_exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Nix parser test executable
    const nix_test = b.addExecutable(.{
        .name = "nix-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parsers/nix-zig/test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    nix_test.root_module.addImport("nix", nix_module);

    const nix_test_step = b.step("nix-test", "Run Nix parser test");
    const nix_test_run = b.addRunArtifact(nix_test);
    if (b.args) |args| {
        nix_test_run.addArgs(args);
    }
    nix_test_step.dependOn(&nix_test_run.step);

    // Nix parser test runner with statistics
    const nix_test_runner = b.addExecutable(.{
        .name = "nix-test-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parsers/nix-zig/test_runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    nix_test_runner.root_module.addImport("nix", nix_module);

    const nix_test_all_step = b.step("nix-test-all", "Run all Nix parser tests");
    const test_runner_run = b.addRunArtifact(nix_test_runner);
    nix_test_all_step.dependOn(&test_runner_run.step);

    // Nix parser benchmark
    const nix_bench = b.addExecutable(.{
        .name = "nix-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parsers/nix-zig/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    nix_bench.root_module.addImport("nix", nix_module);

    const nix_bench_step = b.step("nix-bench", "Run Nix parser benchmark");
    const bench_run = b.addRunArtifact(nix_bench);
    nix_bench_step.dependOn(&bench_run.step);

    // Nix parser comparison benchmark (vs Rust rnix-parser)
    const nix_bench_compare = b.addExecutable(.{
        .name = "nix-bench-compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parsers/nix-zig/bench_compare.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    nix_bench_compare.root_module.addImport("nix", nix_module);

    const nix_bench_compare_step = b.step("bench-compare", "Compare Zig parser vs Rust rnix-parser");
    const bench_compare_run = b.addRunArtifact(nix_bench_compare);
    nix_bench_compare_step.dependOn(&bench_compare_run.step);

    // Automated benchmark suite with JSON export
    const nix_bench_auto = b.addExecutable(.{
        .name = "nix-bench-auto",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parsers/nix-zig/bench_auto.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    nix_bench_auto.root_module.addImport("nix", nix_module);

    const nix_bench_auto_step = b.step("bench-auto", "Run automated benchmark suite (Criterion-style)");
    const bench_auto_run = b.addRunArtifact(nix_bench_auto);
    nix_bench_auto_step.dependOn(&bench_auto_run.step);

    // CCL example executable
    const ccl_example = b.addExecutable(.{
        .name = "ccl-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parsers/ccl-zig/examples/example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    ccl_example.root_module.addImport("ccl", ccl_module);

    const ccl_example_step = b.step("ccl-example", "Run CCL example");
    const ccl_example_run = b.addRunArtifact(ccl_example);
    ccl_example_step.dependOn(&ccl_example_run.step);
}
