//! Transported terminal views adapted to canonical Howl Render.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bundled = b.option(bool, "bundled_text", "Use the bundled Howl Text backend") orelse false;
    const client = b.dependency("server_client", .{ .target = target, .optimize = optimize });
    const render = b.dependency("howl_render", .{ .target = target, .optimize = optimize, .bundled_text = bundled });
    const text = b.dependency("howl_text", .{ .target = target, .optimize = optimize, .bundled = bundled });
    const vt = b.dependency("howl_vt", .{ .target = target, .optimize = optimize });
    const native_render = render.module("howl_render_native");
    const header = b.addTranslateC(.{
        .root_source_file = b.path("include/howl_server_client_render.h"),
        .target = target,
        .optimize = optimize,
    });
    header.addIncludePath(render.namedLazyPath("howl_render_native_header").dirname());

    const adapter = b.addModule("server_client_render", .{
        .root_source_file = b.path("src/render.zig"),
        .target = target,
        .optimize = optimize,
    });
    adapter.addImport("terminal_client", client.module("terminal_client"));
    adapter.addImport("howl_render", render.module("howl_render"));

    const native = b.addModule("server_client_render_native", .{
        .root_source_file = b.path("src/native.zig"),
        .target = target,
        .optimize = optimize,
    });
    native.addImport("terminal_client", client.module("terminal_client"));
    native.addImport("server_client_render", adapter);
    native.addImport("howl_render_native", native_render);
    native.addImport("render_abi_types", header.createModule());
    b.addNamedLazyPath("server_client_render_header", b.path("include/howl_server_client_render.h"));

    const composite = b.createModule(.{
        .root_source_file = b.path("src/abi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
    });
    composite.addImport("server_client_abi", client.module("server_client_abi"));
    composite.addImport("server_client_render_native", native);
    const library = b.addLibrary(.{ .name = "howl_sessions_native", .linkage = .dynamic, .root_module = composite });
    library.installHeader(b.path("include/howl_server_client_render.h"), "howl_server_client_render.h");
    library.installHeader(client.namedLazyPath("server_client_header"), "howl_server_client.h");
    library.installHeader(render.namedLazyPath("howl_render_native_header"), "howl_render_native.h");
    library.installHeader(vt.namedLazyPath("howl_vt_native_header"), "howl_vt_native.h");
    b.installArtifact(library);

    // Forward Render's exact native records, never redeclare its ABI.
    // zig-audit: acknowledge panic
    // reason: Build graph allocation failure cannot be recovered while forwarding a module.
    b.modules.put(b.allocator, "server_client_render_native", render.module("howl_render_native")) catch @panic("OOM");

    const proof = b.createModule(.{
        .root_source_file = b.path("test/render.zig"),
        .target = target,
        .optimize = optimize,
    });
    proof.addImport("terminal_client", client.module("terminal_client"));
    proof.addImport("server_client_render", adapter);
    proof.addImport("server_client_render_native", native);
    proof.addImport("howl_vt", vt.module("howl_vt"));
    proof.addImport("test_fonts", text.module("howl_text_test_fonts"));
    const tests = b.addTest(.{ .name = "server-client-render", .root_module = proof, .use_llvm = false, .use_lld = false });

    const check = b.step("check", "Compile the transported Render adapter and its proofs");
    const test_step = b.step("test", "Run transported Render tests");
    check.dependOn(&tests.step);
    check.dependOn(&library.step);
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const foreign_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    foreign_module.linkLibrary(library);
    foreign_module.addIncludePath(b.path("include"));
    foreign_module.addIncludePath(client.namedLazyPath("server_client_header").dirname());
    foreign_module.addIncludePath(render.namedLazyPath("howl_render_native_header").dirname());
    foreign_module.addIncludePath(vt.namedLazyPath("howl_vt_native_header").dirname());
    foreign_module.addCSourceFile(.{ .file = b.path("test/foreign.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    const foreign = b.addExecutable(.{ .name = "server-client-render-foreign", .root_module = foreign_module });
    check.dependOn(&foreign.step);
    const run_foreign = b.addRunArtifact(foreign);
    run_foreign.addFileArg(text.namedLazyPath("howl_text_test_font"));
    test_step.dependOn(&run_foreign.step);

    const audit = b.step("audit", "Audit this package in its Git release root");
    const zig_audit = b.addSystemCommand(&.{ "zig-audit", "check" });
    zig_audit.setCwd(b.path("."));
    audit.dependOn(&zig_audit.step);
    b.default_step = check;
}
