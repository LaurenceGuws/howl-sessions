const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const server = b.dependency("server", .{ .target = target, .optimize = optimize });
    const client = b.dependency("server_client", .{ .target = target, .optimize = optimize });

    const module = b.addModule("howl_cli", .{
        .root_source_file = b.path("src/howl_cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("server_client", client.module("server_client"));

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root.addImport("howl_cli", module);
    root.addImport("server_client", client.module("server_client"));
    root.addImport("server_runtime", server.module("server_runtime"));
    const executable = b.addExecutable(.{ .name = "howl", .root_module = root });
    b.installArtifact(executable);

    const tests = b.addTest(.{
        .name = "howl-cli",
        .root_module = module,
        .use_llvm = false,
        .use_lld = false,
    });

    const runtime_test_root = b.createModule(.{
        .root_source_file = b.path("test/server_runtime.zig"),
        .target = target,
        .optimize = optimize,
    });
    runtime_test_root.addImport("server_runtime", server.module("server_runtime"));
    runtime_test_root.addImport("server_client", client.module("server_client"));
    const runtime_tests = b.addTest(.{
        .name = "howl-cli-server-runtime",
        .root_module = runtime_test_root,
        .use_llvm = false,
        .use_lld = false,
    });
    const check = b.step("check", "Compile the native Howl CLI");
    const audit = b.step("audit", "Audit every owned Zig source file");
    const zig_audit = b.addSystemCommand(&.{ "zig-audit", "check" });
    zig_audit.setCwd(b.path("."));
    audit.dependOn(&zig_audit.step);
    check.dependOn(audit);
    check.dependOn(&executable.step);
    check.dependOn(&tests.step);
    check.dependOn(&runtime_tests.step);
    const test_step = b.step("test", "Run native Howl CLI proofs");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(runtime_tests).step);

    const interface_test = b.addSystemCommand(&.{"python3"});
    interface_test.addFileArg(b.path("test/interface.py"));
    interface_test.addArtifactArg(executable);
    interface_test.setName("Howl CLI interface");
    test_step.dependOn(&interface_test.step);

    const managed_test = b.addSystemCommand(&.{"python3"});
    managed_test.addFileArg(b.path("test/managed_instance.py"));
    managed_test.addArtifactArg(executable);
    managed_test.setName("Howl managed CLI interaction");
    test_step.dependOn(&managed_test.step);
    const lifecycle_test = b.addSystemCommand(&.{"python3"});
    lifecycle_test.addFileArg(b.path("test/server_lifecycle.py"));
    lifecycle_test.addArtifactArg(executable);
    lifecycle_test.setName("Howl Server lifetime boundaries");
    test_step.dependOn(&lifecycle_test.step);
    b.default_step = check;
}
