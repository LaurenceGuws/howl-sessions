//! The Server-owned control and terminal wire; no live terminal or network.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // The wire and Client share this exact codec module. Encoding borrows a VT
    // observation only when a Server selects it; protocol readers own no VT.
    const codec = b.addModule("terminal_observation_codec", .{
        .root_source_file = b.path("src/observation_codec.zig"),
        .target = target,
        .optimize = optimize,
    });
    const protocol = b.addModule("server_protocol", .{
        .root_source_file = b.path("src/protocol/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    protocol.addImport("terminal_observation_codec", codec);
    b.addNamedLazyPath("server_protocol_vectors", b.path("protocol/vectors.json"));

    const proof = b.addTest(.{
        .name = "server-protocol",
        .root_module = protocol,
        .use_llvm = false,
        .use_lld = false,
    });
    const codec_proof = b.addTest(.{ .name = "terminal-observation-codec", .root_module = codec, .use_llvm = false, .use_lld = false });
    const vectors = b.addSystemCommand(&.{ "python3", "tools/validate_vectors.py", "protocol/vectors.json" });
    vectors.setCwd(b.path("."));
    const wire = b.step("wire", "Validate the independent Server wire vectors");
    wire.dependOn(&vectors.step);

    const check = b.step("check", "Compile the Server protocol and validate vectors");
    check.dependOn(&proof.step);
    check.dependOn(&codec_proof.step);
    check.dependOn(wire);
    const tests = b.step("test", "Run Server protocol proofs and wire vectors");
    tests.dependOn(&b.addRunArtifact(proof).step);
    tests.dependOn(&b.addRunArtifact(codec_proof).step);
    tests.dependOn(wire);

    const audit = b.step("audit", "Audit this package in its Git release root");
    const zig_audit = b.addSystemCommand(&.{ "zig-audit", "check" });
    zig_audit.setCwd(b.path("."));
    audit.dependOn(&zig_audit.step);
    b.default_step = check;
}
