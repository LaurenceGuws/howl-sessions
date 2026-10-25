//! Owns the optional Server family and independently selectable consumer graphs.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bundled = b.option(bool, "bundled_render_text", "Build the client render adapter with bundled howl-text") orelse false;
    const windows = target.result.os.tag == .windows;
    const vt = b.dependency("howl_vt", .{ .target = target, .optimize = optimize });
    const codec = vt.module("howl_vt_codec");
    const instance = b.dependency("howl_instance", .{ .target = target, .optimize = optimize }).module("howl_instance_headless");

    const wire_owner = b.dependency("server_protocol", .{ .target = target, .optimize = optimize });
    const protocol = wire_owner.module("server_protocol");
    // Existing consumers retain the exact package-owned module identity.
    // zig-audit: acknowledge panic
    // reason: Build graph allocation failure is unrecoverable while forwarding an owned module.
    b.modules.put(b.allocator, "server_protocol", protocol) catch @panic("OOM");

    const byte_client = b.addModule("server_client_byte", .{
        .root_source_file = b.path("src/client/terminal/byte.zig"),
        .target = target,
        .optimize = optimize,
    });
    byte_client.addImport("server_protocol", protocol);

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

    const transport = b.createModule(.{
        .root_source_file = b.path(if (windows) "src/client/transport/transport_windows.zig" else "src/client/transport/transport.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (windows) transport.linkSystemLibrary("ws2_32", .{});
    const terminal_owner = b.createModule(.{
        .root_source_file = b.path("src/client/terminal/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    terminal_owner.addImport("server_protocol", protocol);
    terminal_owner.addImport("client_transport", transport);
    const terminal = b.createModule(.{
        .root_source_file = b.path("src/client/terminal/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    terminal.addImport("server_protocol", protocol);
    terminal.addImport("server_client_byte", byte_client);
    terminal.addImport("howl_vt_codec", codec);
    terminal.addImport("terminal_owner", terminal_owner);
    const control_owner = b.createModule(.{
        .root_source_file = b.path("src/client/control.zig"),
        .target = target,
        .optimize = optimize,
    });
    control_owner.addImport("server_protocol", protocol);
    control_owner.addImport("client_transport", transport);
    control_owner.addImport("terminal_client", terminal);
    control_owner.addImport("terminal_owner", terminal_owner);
    const client = b.addModule("server_client", .{
        .root_source_file = b.path("src/client/server_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    client.addImport("server_protocol", protocol);
    client.addImport("control_owner", control_owner);
    client.addImport("terminal_client", terminal);

    const abi_types = b.addTranslateC(.{
        .root_source_file = b.path("include/howl_server_client.h"),
        .target = target,
        .optimize = optimize,
    });
    abi_types.addIncludePath(vt.namedLazyPath("howl_vt_native_header").dirname());
    const native_types = abi_types.createModule();
    const native = b.addModule("server_client_native", .{ .root_source_file = b.path("src/client/native.zig"), .target = target, .optimize = optimize });
    native.addImport("server_client", client);
    native.addImport("howl_vt_codec", codec);
    native.addImport("native_abi_types", native_types);
    native.addImport("terminal_owner", terminal_owner);
    const abi_root = b.createModule(.{
        .root_source_file = b.path("src/client/abi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    abi_root.addImport("server_client", client);
    abi_root.addImport("native_abi_types", native_types);
    abi_root.addImport("client_native", native);
    const abi = b.addLibrary(.{ .name = "howl_server_client", .linkage = .static, .root_module = abi_root });
    abi.installHeader(b.path("include/howl_server_client.h"), "howl_server_client.h");
    abi.installHeader(vt.namedLazyPath("howl_vt_native_header"), "howl_vt_native.h");
    b.installArtifact(abi);
    const render = b.dependency("howl_render", .{ .target = target, .optimize = optimize, .bundled_text = bundled });
    // Forward the exact Render-owned native module beside the transported adapter.
    // zig-audit: acknowledge panic
    // reason: Build graph allocation failure is unrecoverable while forwarding this child-owned module.
    b.modules.put(b.allocator, "server_client_render_native", render.module("howl_render_native")) catch @panic("OOM");
    const text = b.dependency("howl_text", .{ .target = target, .optimize = optimize, .bundled = bundled });
    const adapter = b.addModule("server_client_render", .{
        .root_source_file = b.path("src/client/terminal/render.zig"),
        .target = target,
        .optimize = optimize,
    });
    adapter.addImport("terminal_client", terminal);
    adapter.addImport("howl_render", render.module("howl_render"));

    const control_tests = b.createModule(.{
        .root_source_file = b.path("test/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    control_tests.addImport("server_client", client);
    control_tests.addImport("server_model", model);
    control_tests.addImport("server_service", service);
    control_tests.addImport("client_transport", transport);
    control_tests.addImport("terminal_owner", terminal_owner);
    control_tests.addImport("control_owner", control_owner);
    const render_tests = b.createModule(.{
        .root_source_file = b.path("src/client/terminal/render_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    render_tests.addImport("terminal_client", terminal);
    render_tests.addImport("server_client_render", adapter);
    render_tests.addImport("howl_vt", vt.module("howl_vt"));
    render_tests.addImport("test_fonts", text.module("howl_text_test_fonts"));
    const owner = b.createModule(.{
        .root_source_file = b.path("test/owner.zig"),
        .target = target,
        .optimize = optimize,
    });
    owner.addImport("server", model);

    // Public client composition receives only these independently selected roots.
    const client_boundary = b.createModule(.{
        .root_source_file = b.path("test/client_boundary.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_boundary.addImport("server_client", client);
    client_boundary.addImport("server_protocol", protocol);

    const check = b.step("check", "Compile the optional Server family and its consumer proofs");
    const audit = b.step("audit", "Audit every owned Zig source file");
    const zig_audit = b.addSystemCommand(&.{ "zig-audit", "check" });
    zig_audit.setCwd(b.path("."));
    audit.dependOn(&zig_audit.step);
    check.dependOn(audit);
    check.dependOn(&abi.step);
    const tests = b.step("test", "Run Server runtime, wire, client and render proofs");
    inline for (.{
        .{ "server", model },
        .{ "server-service", service },
        .{ "server-runtime", runtime },
        .{ "server-owner-api", owner },
        .{ "server-client", control_tests },
        .{ "server-client-boundary", client_boundary },
        .{ "server-terminal-client", terminal },
        .{ "server-client-render", render_tests },
        .{ "server-client-transport", transport },
    }) |proof| {
        const artifact = b.addTest(.{ .name = proof[0], .root_module = proof[1], .use_llvm = false, .use_lld = false });
        check.dependOn(&artifact.step);
        tests.dependOn(&b.addRunArtifact(artifact).step);
    }
    const byte_tests = b.createModule(.{
        .root_source_file = b.path("test/byte.zig"),
        .target = target,
        .optimize = optimize,
    });
    byte_tests.addImport("server_client_byte", byte_client);
    byte_tests.addImport("server_protocol", protocol);
    const byte_proof = b.addTest(.{ .name = "server-client-byte", .root_module = byte_tests, .use_llvm = false, .use_lld = false });
    check.dependOn(&byte_proof.step);
    const byte_run = b.addRunArtifact(byte_proof);
    tests.dependOn(&byte_run.step);
    b.step("test:byte", "Qualify caller-driven byte attachment transactions").dependOn(&byte_run.step);
    if (target.result.os.tag == .linux) {
        const artifact = b.addTest(.{ .name = "server-terminal-service", .root_module = terminal_service, .use_llvm = false, .use_lld = false });
        check.dependOn(&artifact.step);
        tests.dependOn(&b.addRunArtifact(artifact).step);
    }
    if (!windows) {
        // Separate process so the proof owns SIGPIPE policy.
        const sigpipe_root = b.createModule(.{
            .root_source_file = b.path("test/transport_sigpipe.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        sigpipe_root.addImport("client_transport", transport);
        const sigpipe = b.addExecutable(.{ .name = "server-transport-sigpipe", .root_module = sigpipe_root });
        check.dependOn(&sigpipe.step);
        tests.dependOn(&b.addRunArtifact(sigpipe).step);
    }
    if (target.result.os.tag == .linux) {
        const foreign_root = b.createModule(.{
            .root_source_file = b.path("test/native_abi.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        foreign_root.addImport("server_runtime", runtime);
        foreign_root.linkLibrary(abi);
        foreign_root.addCSourceFile(.{ .file = b.path("test/native_client.c"), .flags = &.{ "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra", "-Werror" } });
        foreign_root.addCSourceFile(.{ .file = b.path("test/native_queries.c"), .flags = &.{ "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra", "-Werror" } });
        foreign_root.addCSourceFile(.{ .file = b.path("test/query_header.cpp"), .flags = &.{ "-std=c++17", "-Wall", "-Wextra", "-Werror" } });
        const foreign = b.addTest(.{ .name = "server-client-native-abi", .root_module = foreign_root });
        check.dependOn(&foreign.step);
        tests.dependOn(&b.addRunArtifact(foreign).step);
    }
    const native_proof = b.addTest(.{ .name = "server-client-native-semantics", .root_module = native, .use_llvm = false, .use_lld = false });
    check.dependOn(&native_proof.step);
    const native_run = b.addRunArtifact(native_proof);
    tests.dependOn(&native_run.step);
    b.step("test:native", "Qualify native client semantics and lifecycle boundaries").dependOn(&native_run.step);
    const wire = b.step("wire", "Validate the Server terminal wire corpus");
    wire.dependOn(&wire_owner.builder.top_level_steps.get("wire").?.step);
    check.dependOn(wire);
    tests.dependOn(wire);
    b.default_step = check;
}
