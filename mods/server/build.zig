//! Owns Server, Session and Instance lifetimes, never a product client's state.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vt = b.dependency("howl_vt", .{ .target = target, .optimize = optimize });
    const codec = vt.module("howl_vt_codec");
    const instance = b.dependency("howl_instance", .{ .target = target, .optimize = optimize }).module("howl_instance_headless");
    const wire_owner = b.dependency("server_protocol", .{ .target = target, .optimize = optimize });
    const protocol = wire_owner.module("server_protocol");
    // Existing consumers retain the same protocol package identity.
    // zig-audit: acknowledge panic
    // reason: Build graph allocation failure cannot be recovered while forwarding a module.
    b.modules.put(b.allocator, "server_protocol", protocol) catch @panic("OOM");

    const terminal_service = b.addModule("server_terminal_service", .{
        .root_source_file = b.path("src/terminal_service.zig"),
        .target = target,
        .optimize = optimize,
    });
    terminal_service.addImport("howl_instance", instance);
    terminal_service.addImport("server_protocol", protocol);
    terminal_service.addImport("howl_vt_codec", codec);
    const model = b.addModule("server", .{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    model.addImport("server_protocol", protocol);
    model.addImport("howl_instance", instance);
    model.addImport("server_terminal_service", terminal_service);
    const service = b.addModule("server_service", .{
        .root_source_file = b.path("src/service.zig"),
        .target = target,
        .optimize = optimize,
    });
    service.addImport("server_model", model);
    service.addImport("server_protocol", protocol);
    service.addImport("howl_instance", instance);
    const runtime = b.addModule("server_runtime", .{
        .root_source_file = b.path("src/runtime.zig"),
        .target = target,
        .optimize = optimize,
    });
    runtime.addImport("server_protocol", protocol);
    runtime.addImport("server_model", model);
    runtime.addImport("server_service", service);
    runtime.addImport("howl_instance", instance);

    const owner = b.createModule(.{
        .root_source_file = b.path("test/owner.zig"),
        .target = target,
        .optimize = optimize,
    });
    owner.addImport("server", model);
    const check = b.step("check", "Compile listener-free Server and its cross-boundary proofs");
    const audit = b.step("audit", "Audit this package in its Git release root");
    const zig_audit = b.addSystemCommand(&.{ "zig-audit", "check" });
    zig_audit.setCwd(b.path("."));
    audit.dependOn(&zig_audit.step);
    check.dependOn(audit);
    const tests = b.step("test", "Run Server, listener and real-client integration proofs");
    inline for (.{
        .{ "server", model },
        .{ "server-service", service },
        .{ "server-runtime", runtime },
        .{ "server-owner-api", owner },
    }) |proof| {
        const artifact = b.addTest(.{ .name = proof[0], .root_module = proof[1], .use_llvm = false, .use_lld = false });
        check.dependOn(&artifact.step);
        tests.dependOn(&b.addRunArtifact(artifact).step);
    }
    if (target.result.os.tag == .linux) {
        const artifact = b.addTest(.{ .name = "server-terminal-service", .root_module = terminal_service, .use_llvm = false, .use_lld = false });
        check.dependOn(&artifact.step);
        tests.dependOn(&b.addRunArtifact(artifact).step);
    }

    // Integration is a consumer of server_client, never part of Server itself.
    // Client has no dependency on Server, including its tests.
    const consumer = b.dependency("server_client", .{ .target = target, .optimize = optimize });
    const client = consumer.module("server_client");
    const client_tests = b.createModule(.{
        .root_source_file = b.path("test/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_tests.addImport("server_client", client);
    client_tests.addImport("server_model", model);
    client_tests.addImport("server_service", service);
    client_tests.addImport("client_transport", consumer.module("client_transport"));
    client_tests.addImport("terminal_owner", consumer.module("terminal_owner"));
    client_tests.addImport("control_owner", consumer.module("control_owner"));
    const integrated = b.addTest(.{ .name = "server-client-live", .root_module = client_tests, .use_llvm = false, .use_lld = false });
    check.dependOn(&integrated.step);
    tests.dependOn(&b.addRunArtifact(integrated).step);
    if (target.result.os.tag == .linux) {
        const foreign_root = b.createModule(.{
            .root_source_file = b.path("test/native_abi.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        foreign_root.addImport("server_runtime", runtime);
        foreign_root.addIncludePath(consumer.namedLazyPath("server_client_header").dirname());
        foreign_root.linkLibrary(consumer.artifact("howl_server_client"));
        foreign_root.addCSourceFile(.{ .file = b.path("test/native_client.c"), .flags = &.{ "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra", "-Werror" } });
        foreign_root.addCSourceFile(.{ .file = b.path("test/native_queries.c"), .flags = &.{ "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra", "-Werror" } });
        foreign_root.addCSourceFile(.{ .file = b.path("test/query_header.cpp"), .flags = &.{ "-std=c++17", "-Wall", "-Wextra", "-Werror" } });
        const foreign = b.addTest(.{ .name = "server-client-native-abi", .root_module = foreign_root });
        check.dependOn(&foreign.step);
        tests.dependOn(&b.addRunArtifact(foreign).step);
    }
    const wire = b.step("wire", "Validate independent Server wire vectors");
    wire.dependOn(&wire_owner.builder.top_level_steps.get("wire").?.step);
    check.dependOn(wire);
    tests.dependOn(wire);
    b.default_step = check;
}
