//! Full shared terminal-renderer WebAssembly canary.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize: std.builtin.OptimizeMode = .ReleaseSafe;
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
        .cpu_features_add = std.Target.wasm.featureSet(&.{ .exception_handling, .reference_types }),
    });
    const client = b.dependency("server_client", .{
        .target = target,
        .optimize = optimize,
        .bundled_render_text = true,
    });
    const wire_owner = b.dependency("server_protocol", .{ .target = target, .optimize = optimize });
    const vectors = wire_owner.namedLazyPath("server_protocol_vectors");
    const client_module = client.module("server_client");
    const text = b.dependency("howl_text", .{
        .target = target,
        .optimize = optimize,
        .bundled = true,
    });
    const root = b.createModule(.{
        .root_source_file = b.path("probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .strip = true,
    });
    root.addImport("server_client", client_module);
    root.addImport("server_client_render", client.module("server_client_render"));
    root.export_symbol_names = &.{
        "font_ptr",   "font_capacity", "run",       "report_ptr", "report_len",
        "pixels_ptr", "pixels_len",    "error_ptr", "error_len",
    };
    const wasm = b.addExecutable(.{ .name = "howl-render-proof", .root_module = root });
    wasm.entry = .disabled;
    wasm.export_memory = true;
    wasm.initial_memory = 96 * 1024 * 1024;
    wasm.max_memory = 128 * 1024 * 1024;
    wasm.wasi_exec_model = .reactor;

    const check = b.step("check", "Run shared terminal renderer in Wasm on one bounded semantic view");
    const audit = b.step("audit", "Audit every owned Zig source file");
    const zig_audit = b.addSystemCommand(&.{ "zig-audit", "check" });
    zig_audit.setCwd(b.path("."));
    audit.dependOn(&zig_audit.step);
    // The workspace checks all Git-owned Zig source in one root audit.
    // Standalone package releases run this package's "audit" step explicitly.
    const run = b.addSystemCommand(&.{ "node", "tests/check.mjs" });
    run.setCwd(b.path("."));
    run.addFileArg(wasm.getEmittedBin());
    run.addFileArg(text.path("testdata/primary.ttf"));
    check.dependOn(&run.step);

    const live_root = b.createModule(.{
        .root_source_file = b.path("live.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .strip = true,
    });
    live_root.addImport("server_client", client_module);
    live_root.addImport("server_client_render", client.module("server_client_render"));
    live_root.addImport("howl_render_native", client.module("server_client_render_native"));
    live_root.export_symbol_names = &.{
        "rv_font_ptr",               "rv_font_capacity",            "rv_fallback_font_ptr",
        "rv_fallback_font_capacity", "rv_symbol_font_ptr",          "rv_symbol_font_capacity",
        "rv_snapshot_ptr",           "rv_snapshot_capacity",        "rv_frame_ptr",
        "rv_frame_len",              "rv_commands_ptr",             "rv_commands_count",
        "rv_commands_stride",        "rv_text_ptr",                 "rv_text_len",
        "rv_text_truncated",         "rv_pixels_ptr",               "rv_pixels_len",
        "rv_error_ptr",              "rv_error_len",                "rv_render_count",
        "rv_frame_format",           "rv_set_frame_format",         "rv_ready",
        "rv_init",                   "rv_init_presentation",        "rv_missing_external",
        "rv_missing_resource",       "rv_missing_generation",       "rv_missing_format",
        "rv_missing_width",          "rv_missing_height",           "rv_missing_stride",
        "rv_missing_image_id",       "rv_missing_image_generation", "rv_accept_external",
        "rv_reset",                  "rv_render",                   "rv_ack",
    };
    const live = b.addExecutable(.{ .name = "howl-live-render", .root_module = live_root });
    live.entry = .disabled;
    live.export_memory = true;
    live.initial_memory = 192 * 1024 * 1024;
    live.max_memory = 256 * 1024 * 1024;
    live.wasi_exec_model = .reactor;

    b.installArtifact(wasm);
    b.installArtifact(live);

    // The accepted check compiles both the synthetic proof and the live renderer.
    check.dependOn(&live.step);
    const external_image_test = b.addSystemCommand(&.{ "node", "tests/external_image.mjs" });
    external_image_test.setCwd(b.path("."));
    external_image_test.addFileArg(live.getEmittedBin());
    external_image_test.addFileArg(text.path("testdata/primary.ttf"));
    external_image_test.addFileArg(text.path("testdata/fira-code-medium.otf"));
    external_image_test.addFileArg(b.path("fonts/SymbolsNerdFontMono-Regular.ttf"));
    external_image_test.addFileArg(vectors);
    external_image_test.setName("live renderer external image residency");
    check.dependOn(&external_image_test.step);
    const external_image_v4_test = b.addSystemCommand(&.{ "node", "tests/external_image_v4.mjs" });
    external_image_v4_test.setCwd(b.path("."));
    external_image_v4_test.addFileArg(live.getEmittedBin());
    external_image_v4_test.addFileArg(text.path("testdata/primary.ttf"));
    external_image_v4_test.addFileArg(text.path("testdata/fira-code-medium.otf"));
    external_image_v4_test.addFileArg(b.path("fonts/SymbolsNerdFontMono-Regular.ttf"));
    external_image_v4_test.addFileArg(vectors);
    external_image_v4_test.setName("live renderer v4 external image residency");
    check.dependOn(&external_image_v4_test.step);
    const multi_image_test = b.addSystemCommand(&.{ "node", "tests/multi_image.mjs" });
    multi_image_test.setCwd(b.path("."));
    multi_image_test.addFileArg(live.getEmittedBin());
    multi_image_test.addFileArg(text.path("testdata/primary.ttf"));
    multi_image_test.addFileArg(text.path("testdata/fira-code-medium.otf"));
    multi_image_test.addFileArg(b.path("fonts/SymbolsNerdFontMono-Regular.ttf"));
    multi_image_test.addFileArg(vectors);
    multi_image_test.setName("live renderer bounded multi image residency");
    check.dependOn(&multi_image_test.step);
    const multi_image_v4_test = b.addSystemCommand(&.{ "node", "tests/multi_image_v4.mjs" });
    multi_image_v4_test.setCwd(b.path("."));
    multi_image_v4_test.addFileArg(live.getEmittedBin());
    multi_image_v4_test.addFileArg(text.path("testdata/primary.ttf"));
    multi_image_v4_test.addFileArg(text.path("testdata/fira-code-medium.otf"));
    multi_image_v4_test.addFileArg(b.path("fonts/SymbolsNerdFontMono-Regular.ttf"));
    multi_image_v4_test.addFileArg(vectors);
    multi_image_v4_test.setName("live renderer v4 bounded multi image residency");
    check.dependOn(&multi_image_v4_test.step);
    const visible_text_test = b.addSystemCommand(&.{ "node", "tests/visible_text.mjs" });
    visible_text_test.setCwd(b.path("."));
    visible_text_test.addFileArg(live.getEmittedBin());
    visible_text_test.addFileArg(text.path("testdata/primary.ttf"));
    visible_text_test.addFileArg(text.path("testdata/fira-code-medium.otf"));
    visible_text_test.addFileArg(b.path("fonts/SymbolsNerdFontMono-Regular.ttf"));
    visible_text_test.addFileArg(vectors);
    visible_text_test.setName("live renderer visible text projection");
    check.dependOn(&visible_text_test.step);
    const frame_compat_test = b.addSystemCommand(&.{ "node", "tests/frame_compat.mjs" });
    frame_compat_test.setCwd(b.path("."));
    frame_compat_test.addFileArg(live.getEmittedBin());
    frame_compat_test.addFileArg(text.path("testdata/primary.ttf"));
    frame_compat_test.addFileArg(text.path("testdata/fira-code-medium.otf"));
    frame_compat_test.addFileArg(b.path("fonts/SymbolsNerdFontMono-Regular.ttf"));
    frame_compat_test.addFileArg(vectors);
    frame_compat_test.setName("live renderer frame generation compatibility");
    check.dependOn(&frame_compat_test.step);
    const asset_contract_test = b.addSystemCommand(&.{ "node", "tests/asset_contract.mjs" });
    asset_contract_test.setCwd(b.path("."));
    asset_contract_test.setName("browser module asset contract");
    check.dependOn(&asset_contract_test.step);
    const host_syntax = b.addSystemCommand(&.{ "node", "--check", "web/host.mjs" });
    host_syntax.setCwd(b.path("."));
    host_syntax.setName("live browser host syntax");
    check.dependOn(&host_syntax.step);
    const webgl_test = b.addSystemCommand(&.{ "node", "tests/webgl_backend.mjs" });
    webgl_test.setCwd(b.path("."));
    webgl_test.setName("browser WebGL backend admission");
    check.dependOn(&webgl_test.step);
    const webgl_v4_test = b.addSystemCommand(&.{ "node", "tests/webgl_backend_v4.mjs" });
    webgl_v4_test.setCwd(b.path("."));
    webgl_v4_test.setName("browser WebGL v4 binary command admission");
    check.dependOn(&webgl_v4_test.step);
    const input_test = b.addSystemCommand(&.{ "node", "tests/input.mjs" });
    input_test.setCwd(b.path("."));
    input_test.setName("browser semantic input staging");
    check.dependOn(&input_test.step);
    const pointer_input_test = b.addSystemCommand(&.{ "node", "tests/pointer_input.mjs" });
    pointer_input_test.setCwd(b.path("."));
    pointer_input_test.setName("browser semantic pointer input");
    check.dependOn(&pointer_input_test.step);
    const queue_test = b.addSystemCommand(&.{ "node", "tests/control_queue.mjs" });
    queue_test.setCwd(b.path("."));
    queue_test.setName("browser control queue");
    check.dependOn(&queue_test.step);
    const display_test = b.addSystemCommand(&.{ "node", "tests/display_schedule.mjs" });
    display_test.setCwd(b.path("."));
    display_test.setName("browser display scheduler");
    check.dependOn(&display_test.step);
    const resize_policy_test = b.addSystemCommand(&.{ "node", "tests/resize_policy.mjs" });
    resize_policy_test.setCwd(b.path("."));
    resize_policy_test.setName("browser resize authority policy");
    check.dependOn(&resize_policy_test.step);
    const lifecycle_policy_test = b.addSystemCommand(&.{ "node", "tests/lifecycle_policy.mjs" });
    lifecycle_policy_test.setCwd(b.path("."));
    lifecycle_policy_test.setName("browser lifecycle recovery policy");
    check.dependOn(&lifecycle_policy_test.step);
    const frame_scheduler_test = b.addSystemCommand(&.{ "node", "tests/frame_scheduler.mjs" });
    frame_scheduler_test.setCwd(b.path("."));
    frame_scheduler_test.setName("browser latest-frame scheduler");
    check.dependOn(&frame_scheduler_test.step);
    const telemetry_test = b.addSystemCommand(&.{ "node", "tests/telemetry.mjs" });
    telemetry_test.setCwd(b.path("."));
    telemetry_test.setName("browser telemetry ring");
    check.dependOn(&telemetry_test.step);
    const history_test = b.addSystemCommand(&.{ "node", "tests/history.mjs" });
    history_test.setCwd(b.path("."));
    history_test.setName("browser history viewport model");
    check.dependOn(&history_test.step);
    const selection_test = b.addSystemCommand(&.{ "node", "tests/selection.mjs" });
    selection_test.setCwd(b.path("."));
    selection_test.setName("browser terminal selection model");
    check.dependOn(&selection_test.step);

    const web = b.step("web", "Build the local-only live terminal renderer site");
    web.dependOn(&b.addInstallFile(live.getEmittedBin(), "live-web/render.wasm").step);
    web.dependOn(&b.addInstallFile(text.path("testdata/fira-code-medium.otf"), "live-web/font.bin").step);
    web.dependOn(&b.addInstallFile(text.path("testdata/primary.ttf"), "live-web/fallback-font.bin").step);
    web.dependOn(&b.addInstallFile(b.path("fonts/SymbolsNerdFontMono-Regular.ttf"), "live-web/nerd-font.bin").step);
    web.dependOn(&b.addInstallFile(b.path("fonts/NERD-FONTS-LICENSE.txt"), "live-web/nerd-font-license.txt").step);
    web.dependOn(&b.addInstallFile(text.path("LICENSES/test-fonts.txt"), "live-web/font-licences.txt").step);
    web.dependOn(&b.addInstallFile(text.path("LICENSES/bundled-dependencies.txt"), "live-web/dependencies.txt").step);
    inline for (.{ "index.html", "host.mjs", "frame_v3.mjs", "frame_v4.mjs", "webgl_backend.mjs", "webgl_backend_v3.mjs", "webgl_backend_v4.mjs", "lifecycle_policy.mjs", "input.mjs", "pointer_input.mjs", "history.mjs", "selection.mjs", "control_queue.mjs", "telemetry.mjs", "frame_scheduler.mjs", "display_schedule.mjs", "resize_policy.mjs", "style.css", "manifest.webmanifest", "sw.js", "icon.png" }) |file| {
        web.dependOn(&b.addInstallFile(b.path("web/" ++ file), "live-web/" ++ file).step);
    }
    // The restricted WASI host is shared with the preceding text canary. Keep
    // one implementation while Web is still a monorepo-local experimental client.
    web.dependOn(&b.addInstallFile(b.dependency("howl_web_text", .{}).path("web/runtime.mjs"), "live-web/runtime.mjs").step);

    b.step("test", "Run the complete render canary proof graph").dependOn(check);
    b.default_step = check;
}
