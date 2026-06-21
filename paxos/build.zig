const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "") orelse .ReleaseSafe;

    const cluster_size = b.option(u32, "cluster_size", "Number of nodes in the paxos cluster. Deafaults to 64") orelse 64;

    const options = b.addOptions();
    options.addOption(u32, "cluster_size", cluster_size);
    const build_options_mod = options.createModule();

    const paxos_mod = b.addModule("paxos", .{
        .root_source_file = b.path("src/paxos.zig"),
        .target = target,
        .optimize = optimize,
    });
    paxos_mod.addImport("build_options", build_options_mod);

    const exe = b.addExecutable(.{
        .name = "paxos",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .imports = &.{
            .{ .name = "paxos", .module = paxos_mod },
            .{ .name = "build_options", .module = build_options_mod },
        } }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run.addArgs(args);
    }
    const run_step = b.step("run", "Run the paxos node binary");
    run_step.dependOn(&run.step);

    const echo_exe = b.addExecutable(.{
        .name = "echo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/echo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "paxos", .module = paxos_mod },
            },
        }),
    });
    b.installArtifact(echo_exe);
    const echo_run = b.addRunArtifact(echo_exe);
    const echo_step = b.step("echo", "Run the echo server (port 3000)");
    echo_step.dependOn(&echo_run.step);

    const tests = b.addTest(.{ .root_module = paxos_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
