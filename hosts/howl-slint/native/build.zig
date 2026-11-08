const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bundled = b.option(bool, "bundled_text", "Build pinned FreeType/HarfBuzz for this target") orelse false;
    const render = b.dependency("server_client_render", .{ .target = target, .optimize = optimize, .bundled_text = bundled });
    // This composite exports Client and Client Render, plus their exact headers.
    b.installArtifact(render.artifact("howl_sessions_native"));
    cpuTest(b, target, optimize, render.artifact("howl_sessions_native"));
    b.step("test", "Qualify the pinned remote Sessions ABI set").dependOn(&render.builder.top_level_steps.get("test").?.step);
    const live_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    live_module.linkLibrary(render.artifact("howl_sessions_native"));
    live_module.addIncludePath(b.path("."));
    live_module.addCSourceFiles(.{ .files = &.{ "remote.c", "cpu.c" }, .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    live_module.addCSourceFile(.{ .file = b.path("test/sessions.c"), .flags = &.{ "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra", "-Werror" } });
    const live = b.addExecutable(.{ .name = "sessions-live", .root_module = live_module });
    b.step("build-live", "Install the live integration test executable for a device run").dependOn(&b.addInstallArtifact(live, .{}).step);
    const run = b.addRunArtifact(live);
    run.addPassthruArgs();
    b.step("test-live", "Qualify a disposable Session on an explicit private Server: -- ENDPOINT FONT_PATH").dependOn(&run.step);
    const workload_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    workload_module.linkLibrary(render.artifact("howl_sessions_native"));
    workload_module.addIncludePath(b.path("."));
    workload_module.addCSourceFiles(.{ .files = &.{ "test/workload.c", "remote.c", "cpu.c" }, .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    const workload = b.addExecutable(.{ .name = "sessions-workload", .root_module = workload_module });
    const workload_run = b.addRunArtifact(workload);
    workload_run.addPassthruArgs();
    b.step("benchmark-workload", "Measure a finite workload in a disposable Session: -- ENDPOINT FONT_PATH SHELL_COMMAND").dependOn(&workload_run.step);
}

fn cpuTest(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, abi: *std.Build.Step.Compile) void {
    const module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    module.linkLibrary(abi); // Supplies the exact canonical Render header.
    module.addIncludePath(b.path("."));
    module.addCSourceFiles(.{ .files = &.{ "test/cpu.c", "cpu.c" }, .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    const tests = b.addExecutable(.{ .name = "cpu-test", .root_module = module });
    b.step("test-cpu", "Test the host CPU compositor independently of terminal I/O").dependOn(&b.addRunArtifact(tests).step);
}
