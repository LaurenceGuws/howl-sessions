//! Composes the Web wire, text, render and gateway build graphs.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const native_target = b.standardTargetOptions(.{});
    const native_optimize = b.standardOptimizeOption(.{});
    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const client = b.dependency("server", .{ .target = target, .optimize = .ReleaseSafe });
    const client_module = client.module("server_client");
    const render = b.dependency("howl_render", .{
        .target = target,
        .optimize = .ReleaseSafe,
        .renderer = false,
    });
    const root = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    root.addImport("server_client", client_module);
    root.addImport("server_client_byte", client.module("server_client_byte"));
    root.addImport("limits", render.module("howl_render_limits"));
    const wasm = b.addExecutable(.{ .name = "howl-web", .root_module = root });
    wasm.entry = .disabled;
    root.export_symbol_names = &.{
        "hw_input_ptr",                  "hw_input_capacity",             "hw_output_ptr",                    "hw_output_len",
        "hw_text_ptr",                   "hw_text_len",                   "hw_text_truncated",                "hw_snapshot_ptr",
        "hw_snapshot_len",               "hw_image_ptr",                  "hw_image_len",                     "hw_image_id",
        "hw_image_generation",           "hw_image_width",                "hw_image_height",                  "hw_selection_ptr",
        "hw_selection_len",              "hw_error_ptr",                  "hw_error_len",                     "hw_phase",
        "hw_identity",                   "hw_revision",                   "hw_terminal_revision",             "hw_rows",
        "hw_columns",                    "hw_maximum_rows",               "hw_maximum_columns",               "hw_history_offset",
        "hw_history_count",              "hw_history_row_base",           "hw_alternate_screen",              "hw_leader_present",
        "hw_last_result_code",           "hw_control_ready",              "hw_interaction_terminal_revision", "hw_interaction_alternate_scroll",
        "hw_interaction_mouse_tracking", "hw_interaction_mouse_protocol", "hw_interaction_pointer_mode",      "hw_reset",
        "hw_observe",                    "hw_observe_live",               "hw_request_image",                 "hw_release_image",
        "hw_request_interaction_state",  "hw_request_text_extract",       "hw_send_text",                     "hw_send_paste",
        "hw_send_named_key",             "hw_send_unicode_key",           "hw_send_focus",                    "hw_send_mouse",
        "hw_send_resize",                "hw_send_resize_owned",          "hw_feed",                          "hw_finish",
    };
    wasm.export_memory = true;
    wasm.initial_memory = 32 * 1024 * 1024;
    wasm.max_memory = 32 * 1024 * 1024;
    b.installArtifact(wasm);

    const check = b.step("check", "Run the zero-import Wasm wire and terminal-renderer contract");
    const audit = b.step("audit", "Audit every owned Zig source file");
    const zig_audit = b.addSystemCommand(&.{ "zig-audit", "check" });
    zig_audit.setCwd(b.path("."));
    audit.dependOn(&zig_audit.step);
    check.dependOn(audit);
    const test_command = b.addSystemCommand(&.{ "node", "tests/check.mjs" });
    test_command.setCwd(b.path("."));
    test_command.addFileArg(wasm.getEmittedBin());
    check.dependOn(&test_command.step);
    const live = b.step("live", "Test this Wasm client against a caller-supplied disposable exact Server Instance");
    const live_command = b.addSystemCommand(&.{ "node", "tests/live.mjs" });
    live_command.setCwd(b.path("."));
    live_command.addFileArg(wasm.getEmittedBin());
    live_command.addPassthruArgs();
    live.dependOn(&live_command.step);
    const text = b.dependency("howl_web_text", .{});
    const renderer = b.dependency("howl_web_render", .{});
    const gateway = b.dependency("howl_web_gateway", .{
        .target = native_target,
        .optimize = native_optimize,
    });
    const tests = b.step("test", "Run every Web wire, text, renderer and gateway proof");
    tests.dependOn(&test_command.step);
    inline for (.{ text, renderer, gateway }) |child| {
        check.dependOn(childStep(child, "check"));
        audit.dependOn(childStep(child, "audit"));
        tests.dependOn(childStep(child, "test"));
        for (child.builder.getInstallStep().dependencies.items) |step| {
            const install = step.cast(std.Build.Step.InstallArtifact) orelse continue;
            b.installArtifact(install.artifact);
        }
        for (child.builder.modules.keys(), child.builder.modules.values()) |name, module| {
            std.debug.assert(!b.modules.contains(name));
            // zig-audit: acknowledge panic
            // reason: Build graph construction cannot recover from allocation failure while forwarding the exact child module.
            b.modules.put(b.allocator, name, module) catch @panic("OOM");
        }
        for (child.builder.named_lazy_paths.keys(), child.builder.named_lazy_paths.values()) |name, path| {
            b.addNamedLazyPath(name, path);
        }
    }
    b.step("text-check", "Run native/Wasm text parity").dependOn(childStep(text, "test"));
    b.step("text-web", "Build the local browser text canary").dependOn(childStep(text, "web"));
    b.step("render-check", "Run every Web renderer proof").dependOn(childStep(renderer, "test"));
    const render_web = b.step("render-web", "Build the local live browser renderer canary");
    render_web.dependOn(b.getInstallStep());
    render_web.dependOn(childStep(renderer, "web"));
    b.step("gateway-check", "Run gateway unit and integration proofs").dependOn(childStep(gateway, "test"));
    b.step("gateway-install", "Build the loopback WebSocket gateway").dependOn(gateway.builder.getInstallStep());
    b.default_step = check;
}

fn childStep(child: *std.Build.Dependency, name: []const u8) *std.Build.Step {
    return &child.builder.top_level_steps.get(name).?.step;
}
