//! Builds the loopback-only Howl Web HTTP/WebSocket origin.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const server_client = b.dependency("server", .{
        .target = target,
        .optimize = optimize,
    });
    module.addImport("server_client", server_client.module("server_client"));
    const exe = b.addExecutable(.{ .name = "howl-web-gateway", .root_module = module });
    b.installArtifact(exe);

    const tests = b.addTest(.{ .name = "howl-web-gateway", .root_module = module });
    const check = b.step("check", "Compile and test bounded gateway policy");
    const audit = b.step("audit", "Audit every owned Zig source file");
    const zig_audit = b.addSystemCommand(&.{ "zig-audit", "check" });
    zig_audit.setCwd(b.path("."));
    audit.dependOn(&zig_audit.step);
    check.dependOn(audit);
    check.dependOn(&exe.step);
    check.dependOn(&tests.step);
    const test_step = b.step("test", "Run bounded gateway policy and live byte-bridge proofs");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const integration = b.addSystemCommand(&.{ "python3", "tests/integration.py" });
    integration.setCwd(b.path("."));
    integration.addFileArg(exe.getEmittedBin());
    integration.setName("loopback gateway integration");
    test_step.dependOn(&integration.step);
    b.default_step = check;
}
