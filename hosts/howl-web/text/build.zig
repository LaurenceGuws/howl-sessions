//! Native/Wasm text parity and a local browser canary of the shared text owner.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize: std.builtin.OptimizeMode = .ReleaseSafe;
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
        .cpu_features_add = std.Target.wasm.featureSet(&.{ .exception_handling, .reference_types }),
    });
    const wasm_text = b.dependency("howl_text", .{ .target = target, .optimize = optimize, .bundled = true });
    const native_text = b.dependency("howl_text", .{ .target = b.graph.host, .optimize = optimize, .bundled = true });
    const wasm_root = proofModule(b, target, wasm_text.module("howl_text"), true);
    const wasm = b.addExecutable(.{ .name = "howl-text-proof", .root_module = wasm_root });
    wasm.entry = .disabled;
    wasm.export_memory = true;
    wasm.initial_memory = 64 * 1024 * 1024;
    wasm.max_memory = 96 * 1024 * 1024;
    wasm.wasi_exec_model = .reactor;
    const native_root = proofModule(b, b.graph.host, native_text.module("howl_text"), false);
    const native = b.addLibrary(.{ .name = "howl-text-native-proof", .linkage = .dynamic, .root_module = native_root });

    b.installArtifact(wasm);
    b.installArtifact(native);

    const reference = b.addSystemCommand(&.{ "python3", "tests/native.py" });
    reference.setCwd(b.path("."));
    reference.addFileArg(native.getEmittedBin());
    reference.addFileArg(native_text.path("testdata/primary.ttf"));
    const expected = reference.addOutputDirectoryArg("reference");
    const run = b.addSystemCommand(&.{ "node", "tests/check.mjs" });
    run.setCwd(b.path("."));
    run.addFileArg(wasm.getEmittedBin());
    run.addFileArg(native_text.path("testdata/primary.ttf"));
    run.addDirectoryArg(expected);
    const check = b.step("check", "Verify real native/Wasm text parity and the restricted runtime");
    const audit = b.step("audit", "Audit every owned Zig source file");
    const zig_audit = b.addSystemCommand(&.{ "zig-audit", "check" });
    zig_audit.setCwd(b.path("."));
    audit.dependOn(&zig_audit.step);
    // The workspace checks all Git-owned Zig source in one root audit.
    // Standalone package releases run this package's "audit" step explicitly.
    check.dependOn(&run.step);
    b.step("test", "Run the complete text canary proof graph").dependOn(check);
    b.default_step = check;

    // Local-only test site. Do not publish its font fixture or test reference as
    // the terminal application. This is not an installed PWA or renderer proof.
    const site = b.step("web", "Build the local-only browser text proof");
    site.dependOn(&b.addInstallFile(wasm.getEmittedBin(), "text-web/text-proof.wasm").step);
    site.dependOn(&b.addInstallFile(native_text.path("testdata/primary.ttf"), "text-web/font.bin").step);
    site.dependOn(&b.addInstallFile(expected.path(b, "expected.json"), "text-web/expected.json").step);
    site.dependOn(&b.addInstallFile(native_text.path("LICENSES/bundled-dependencies.txt"), "text-web/dependencies.txt").step);
    site.dependOn(&b.addInstallFile(native_text.path("LICENSES/test-fonts.txt"), "text-web/font-licences.txt").step);
    inline for (.{ "index.html", "host.mjs", "runtime.mjs", "style.css" }) |file| {
        site.dependOn(&b.addInstallFile(b.path("web/" ++ file), "text-web/" ++ file).step);
    }
}

fn proofModule(b: *std.Build, target: std.Build.ResolvedTarget, text: *std.Build.Module, wasm: bool) *std.Build.Module {
    const root = b.createModule(.{
        .root_source_file = b.path("probe.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
        .link_libcpp = true,
        .strip = true,
    });
    root.addImport("howl_text", text);
    root.addCSourceFile(.{
        .file = b.path("tests/jump-proof.c"),
        .flags = if (wasm) &.{ "-mllvm", "-wasm-enable-sjlj", "-mllvm", "-wasm-use-legacy-eh=false" } else &.{},
    });
    root.export_symbol_names = &.{
        "font_input", "font_capacity", "run",        "jump_probe", "result_ptr",
        "result_len", "raster_ptr",    "raster_len", "error_ptr",  "error_len",
    };
    return root;
}
