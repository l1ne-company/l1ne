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

    const nix_targets = addNixParserTargets(b, target, optimize);
    const ccl_targets = addCclParserTargets(b, target, optimize);
    addL1neTargets(b, target, optimize, nix_targets.module, ccl_targets.module);
}

const ParserTargets = struct {
    module: *std.Build.Module,
};

fn addNixParserTargets(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ParserTargets {
    const module = b.addModule("nix", .{
        .root_source_file = b.path("src/parsers/nix-zig/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_exe = b.addExecutable(.{
        .name = "nix-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parsers/nix-zig/test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_exe.root_module.addImport("nix", module);

    const nix_test_step = b.step("nix-test", "Run Nix parser test harness");
    const nix_test_run = b.addRunArtifact(test_exe);
    if (b.args) |args| nix_test_run.addArgs(args);
    nix_test_step.dependOn(&nix_test_run.step);

    const runner = b.addExecutable(.{
        .name = "nix-test-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parsers/nix-zig/test_runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    runner.root_module.addImport("nix", module);

    const nix_all_step = b.step("nix-test-all", "Run curated Nix parser fixtures");
    const runner_cmd = b.addRunArtifact(runner);
    nix_all_step.dependOn(&runner_cmd.step);

    const bench = b.addExecutable(.{
        .name = "nix-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parsers/nix-zig/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    bench.root_module.addImport("nix", module);

    const bench_step = b.step("nix-bench", "Run Nix parser micro-benchmarks");
    const bench_cmd = b.addRunArtifact(bench);
    bench_step.dependOn(&bench_cmd.step);

    const bench_compare = b.addExecutable(.{
        .name = "nix-bench-compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parsers/nix-zig/bench_compare.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    bench_compare.root_module.addImport("nix", module);

    const compare_step = b.step("bench-compare", "Compare Zig parser vs rnix-parser");
    const compare_cmd = b.addRunArtifact(bench_compare);
    compare_step.dependOn(&compare_cmd.step);

    const bench_auto = b.addExecutable(.{
        .name = "nix-bench-auto",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parsers/nix-zig/bench_auto.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    bench_auto.root_module.addImport("nix", module);

    const bench_auto_step = b.step("bench-auto", "Run automated Nix parser benchmarks");
    const bench_auto_cmd = b.addRunArtifact(bench_auto);
    bench_auto_step.dependOn(&bench_auto_cmd.step);

    const aggregate = b.step("nix-zig", "Run Nix parser suite");
    aggregate.dependOn(&nix_test_run.step);
    aggregate.dependOn(&runner_cmd.step);
    aggregate.dependOn(&bench_cmd.step);
    aggregate.dependOn(&compare_cmd.step);
    aggregate.dependOn(&bench_auto_cmd.step);

    return .{ .module = module };
}

fn addCclParserTargets(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ParserTargets {
    const module = b.addModule("ccl", .{
        .root_source_file = b.path("src/parsers/ccl-zig/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const example = b.addExecutable(.{
        .name = "ccl-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parsers/ccl-zig/examples/example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    example.root_module.addImport("ccl", module);

    const example_step = b.step("ccl-example", "Run CCL parser example");
    const example_cmd = b.addRunArtifact(example);
    example_step.dependOn(&example_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parsers/ccl-zig/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("ccl", module);
    const tests_cmd = b.addRunArtifact(tests);

    const aggregate = b.step("ccl-zig", "Run CCL parser suite");
    aggregate.dependOn(&tests_cmd.step);
    aggregate.dependOn(&example_cmd.step);

    return .{ .module = module };
}

fn addL1neTargets(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    nix_module: *std.Build.Module,
    ccl_module: *std.Build.Module,
) void {
    const exe = b.addExecutable(.{
        .name = "l1ne",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/l1ne/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("nix", nix_module);
    exe.root_module.addImport("ccl", ccl_module);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run L1NE orchestrator");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/l1ne/test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("nix", nix_module);
    tests.root_module.addImport("ccl", ccl_module);

    const test_step = b.step("test", "Run L1NE unit tests");
    const test_cmd = b.addRunArtifact(tests);
    test_step.dependOn(&test_cmd.step);
}
