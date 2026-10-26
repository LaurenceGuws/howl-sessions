//! Owns network clients and adapters; it never imports live Server ownership.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shared_abi = b.option(bool, "shared-abi", "Install the client C ABI as a shared library for dynamic hosts") orelse false;
    const windows = target.result.os.tag == .windows;
    const protocol_owner = b.dependency("server_protocol", .{ .target = target, .optimize = optimize });
    const protocol = protocol_owner.module("server_protocol");
    const vt = b.dependency("howl_vt", .{ .target = target, .optimize = optimize });
    const codec = protocol_owner.module("terminal_observation_codec");

    const byte_client = b.addModule("server_client_byte", .{
        .root_source_file = b.path("src/client/terminal/byte.zig"),
        .target = target,
        .optimize = optimize,
    });
    byte_client.addImport("server_protocol", protocol);

    // The concrete transport and control owners are shared with the package's
    // real-Server integration proofs; product callers select server_client.
    const transport = b.addModule("client_transport", .{
        .root_source_file = b.path(if (windows) "src/client/transport/transport_windows.zig" else "src/client/transport/transport.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (windows) transport.linkSystemLibrary("ws2_32", .{});
    const terminal_owner = b.addModule("terminal_owner", .{
        .root_source_file = b.path("src/client/terminal/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    terminal_owner.addImport("server_protocol", protocol);
    terminal_owner.addImport("client_transport", transport);
    // The independently versioned Render adapter consumes this exact client.
    const terminal = b.addModule("terminal_client", .{
        .root_source_file = b.path("src/client/terminal/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    terminal.addImport("server_protocol", protocol);
    terminal.addImport("server_client_byte", byte_client);
    terminal.addImport("terminal_observation_codec", codec);
    terminal.addImport("terminal_owner", terminal_owner);
    const control_owner = b.addModule("control_owner", .{
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

    b.addNamedLazyPath("server_client_header", b.path("include/howl_server_client.h"));
    const abi_types = b.addTranslateC(.{
        .root_source_file = b.path("include/howl_server_client.h"),
        .target = target,
        .optimize = optimize,
    });
    abi_types.addIncludePath(vt.namedLazyPath("howl_vt_native_header").dirname());
    const native_types = abi_types.createModule();
    const native = b.addModule("server_client_native", .{
        .root_source_file = b.path("src/client/native.zig"),
        .target = target,
        .optimize = optimize,
    });
    native.addImport("server_client", client);
    // Validate OSC 52 using the exact grammar used by canonical VT. Server
    // metadata may not substitute for syntax validity or introduce a fork.
    native.addImport("vt_clipboard_grammar", vt.module("vt_clipboard_grammar"));
    native.addImport("native_abi_types", native_types);
    native.addImport("terminal_owner", terminal_owner);
    // Exact-composition hosts can link this source into one native library.
    // Opaque snapshots must never move between independent library instances.
    const abi_root = b.addModule("server_client_abi", .{
        .root_source_file = b.path("src/client/abi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
    });
    abi_root.addImport("server_client", client);
    abi_root.addImport("native_abi_types", native_types);
    abi_root.addImport("client_native", native);
    const abi = b.addLibrary(.{ .name = "howl_server_client", .linkage = if (shared_abi) .dynamic else .static, .root_module = abi_root });
    abi.installHeader(b.path("include/howl_server_client.h"), "howl_server_client.h");
    abi.installHeader(vt.namedLazyPath("howl_vt_native_header"), "howl_vt_native.h");
    b.installArtifact(abi);

    const boundary = b.createModule(.{
        .root_source_file = b.path("test/client_boundary.zig"),
        .target = target,
        .optimize = optimize,
    });
    boundary.addImport("server_client", client);
    boundary.addImport("server_protocol", protocol);
    const byte_tests = b.createModule(.{
        .root_source_file = b.path("test/byte.zig"),
        .target = target,
        .optimize = optimize,
    });
    byte_tests.addImport("server_client_byte", byte_client);
    byte_tests.addImport("server_protocol", protocol);

    const check = b.step("check", "Compile independently selectable Server clients and adapters");
    const audit = b.step("audit", "Audit this package in its Git release root");
    const zig_audit = b.addSystemCommand(&.{ "zig-audit", "check" });
    zig_audit.setCwd(b.path("."));
    audit.dependOn(&zig_audit.step);
    check.dependOn(audit);
    check.dependOn(&abi.step);
    const tests = b.step("test", "Run client, byte, native and transport proofs");
    inline for (.{
        .{ "server-client-boundary", boundary },
        .{ "server-terminal-client", terminal },
        .{ "server-client-transport", transport },
        .{ "server-client-byte", byte_tests },
        .{ "server-client-native-semantics", native },
    }) |proof| {
        const artifact = b.addTest(.{ .name = proof[0], .root_module = proof[1], .use_llvm = false, .use_lld = false });
        check.dependOn(&artifact.step);
        const run = b.addRunArtifact(artifact);
        tests.dependOn(&run.step);
        if (std.mem.eql(u8, proof[0], "server-client-byte"))
            b.step("test:byte", "Qualify caller-driven byte attachment transactions").dependOn(&run.step);
        if (std.mem.eql(u8, proof[0], "server-client-native-semantics"))
            b.step("test:native", "Qualify native client semantics and lifetime").dependOn(&run.step);
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
    b.default_step = check;
}
