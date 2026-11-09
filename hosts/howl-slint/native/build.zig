const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bundled = b.option(bool, "bundled_text", "Build pinned FreeType/HarfBuzz for this target") orelse false;
    const render = b.dependency("server_client_render", .{ .target = target, .optimize = optimize, .bundled_text = bundled });
    // A relocatable object includes the composition's linked FT/HB objects;
    // a plain static archive would leave those transitive archives out.
    const library = render.artifact("howl_sessions_native");
    b.installArtifact(library);
    const object = b.addObject(.{
        .name = "howl_sessions_native",
        .root_module = library.root_module,
        .use_llvm = true,
        .use_lld = target.result.os.tag != .ios,
    });
    object.bundle_compiler_rt = true;
    object.installLibraryHeaders(library);
    const install_object = b.addInstallArtifact(object, .{
        .dest_dir = .{ .override = .lib },
        .h_dir = .{ .override = .header },
        .dest_sub_path = "howl_sessions_native.o",
    });
    b.step("build-static", "Install the complete native composition for static app linkage").dependOn(&install_object.step);
    cpuTest(b, target, optimize, library);
    b.step("test", "Qualify the pinned remote Sessions ABI set").dependOn(&render.builder.top_level_steps.get("test").?.step);
    const live_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    live_module.linkLibrary(library);
    live_module.addIncludePath(b.path("."));
    live_module.addCSourceFiles(.{ .files = &.{ "remote.c", "cpu.c" }, .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    live_module.addCSourceFile(.{ .file = b.path("test/sessions.c"), .flags = &.{ "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra", "-Werror" } });
    const live = b.addExecutable(.{ .name = "sessions-live", .root_module = live_module });
    b.step("build-live", "Install the live integration test executable for a device run").dependOn(&b.addInstallArtifact(live, .{}).step);
    const run = b.addRunArtifact(live);
    run.addPassthruArgs();
    b.step("test-live", "Qualify a disposable Session on an explicit private Server: -- ENDPOINT FONT_PATH").dependOn(&run.step);
    const workload_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    workload_module.linkLibrary(library);
    workload_module.addIncludePath(b.path("."));
    workload_module.addCSourceFiles(.{ .files = &.{ "test/workload.c", "remote.c", "cpu.c" }, .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    const workload = b.addExecutable(.{ .name = "sessions-workload", .root_module = workload_module });
    const workload_run = b.addRunArtifact(workload);
    workload_run.addPassthruArgs();
    b.step("benchmark-workload", "Measure a finite workload in a disposable Session: -- ENDPOINT FONT_PATH SHELL_COMMAND").dependOn(&workload_run.step);
    const observe_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    observe_module.linkLibrary(library);
    observe_module.addIncludePath(b.path("."));
    observe_module.addCSourceFiles(.{ .files = &.{ "test/observe.c", "cpu.c" }, .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    const observe = b.addExecutable(.{ .name = "sessions-observe", .root_module = observe_module });
    const observe_run = b.addRunArtifact(observe);
    observe_run.addPassthruArgs();
    b.step("benchmark-observe", "Compare packed/cached observations through canonical Render: -- ENDPOINT FONT COMMAND MODE [COLS ROWS PIXELS]").dependOn(&observe_run.step);
}

fn cpuTest(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, abi: *std.Build.Step.Compile) void {
    const module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    module.linkLibrary(abi); // Supplies the exact canonical Render header.
    module.addIncludePath(b.path("."));
    module.addCSourceFiles(.{ .files = &.{ "test/cpu.c", "cpu.c" }, .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    const tests = b.addExecutable(.{ .name = "cpu-test", .root_module = module });
    b.step("test-cpu", "Test the host CPU compositor independently of terminal I/O").dependOn(&b.addRunArtifact(tests).step);
}
