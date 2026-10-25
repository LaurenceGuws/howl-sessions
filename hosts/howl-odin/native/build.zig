const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const client_dependency = b.dependency("server_client", .{
        .target = target,
        .optimize = optimize,
        .bundled_render_text = target.result.os.tag != .linux,
    });
    const root = b.createModule(.{
        .root_source_file = b.path("bridge.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
    });
    root.addImport("server_client_render", client_dependency.module("server_client_render"));
    const instance_dependency = b.dependency("howl_instance", .{
        .target = target,
        .optimize = optimize,
        .bundled_render_text = target.result.os.tag != .linux,
    });
    root.addImport("test_fonts", instance_dependency.module("howl_text_test_fonts"));
    root.addImport("server_client", client_dependency.module("server_client"));
    root.addImport("server_client_native", client_dependency.module("server_client_native"));
    root.addImport("howl_instance", instance_dependency.module("howl_instance"));
    root.addImport("howl_vt_native", instance_dependency.module("howl_vt_native"));
    root.addImport("howl_instance_native", instance_dependency.module("howl_instance_native"));
    root.addImport("howl_render_native", instance_dependency.module("howl_render_native"));
    root.addImport("howl_instance_frames_native", instance_dependency.module("howl_instance_frames_native"));
    root.addImport("instance_native_exports", instance_dependency.artifact("howl_instance_native").root_module);

    const library = b.addLibrary(.{
        .name = "howl_odin_bridge",
        .linkage = .dynamic,
        .root_module = root,
    });
    b.installArtifact(library);

    const tests = b.addTest(.{
        .name = "howl-odin-bridge",
        .root_module = root,
        .use_llvm = false,
        .use_lld = false,
    });
    const check = b.step("check", "Compile the Odin bridge and all its proofs");
    const audit = b.step("audit", "Audit every owned Zig source file");
    const zig_audit = b.addSystemCommand(&.{ "zig-audit", "check" });
    zig_audit.setCwd(b.path("."));
    audit.dependOn(&zig_audit.step);
    check.dependOn(audit);
    check.dependOn(&library.step);
    check.dependOn(&tests.step);
    const test_step = b.step("test", "Run Odin bridge ownership and mapping proofs");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
