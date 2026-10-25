//! The tested product snapshot composes, but does not own, its child packages.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const check = b.step("check", "Compile and audit the maintained product packages");
    const tests = b.step("test", "Run every maintained product package's tests");
    const audit = b.step("audit", "Audit maintained product sources");

    for (b.available_deps) |entry| {
        const dep = b.dependency(entry[0], .{ .target = target, .optimize = optimize });
        // Package tests include all their compilation and foreign ABI proofs.
        // zig-audit currently requires the config to live at the Git root,
        // so the workspace runs one audit over every Git-owned Zig source.
        // An independently released child runs its own check at its own root.
        const child_tests = &dep.builder.top_level_steps.get("test").?.step;
        check.dependOn(child_tests);
        tests.dependOn(child_tests);
    }

    // One package identity must serve both direct wire consumers and Server's
    // compatibility export. Duplicating the protocol module would split types.
    const owned_protocol = b.dependency("server_protocol", .{ .target = target, .optimize = optimize }).module("server_protocol");
    const forwarded_protocol = b.dependency("server", .{ .target = target, .optimize = optimize }).module("server_protocol");
    std.debug.assert(owned_protocol == forwarded_protocol);

    const zig_audit = b.addSystemCommand(&.{ "zig-audit", "check" });
    zig_audit.setCwd(b.path("."));
    audit.dependOn(&zig_audit.step);
    check.dependOn(audit);
    b.default_step = check;
}
