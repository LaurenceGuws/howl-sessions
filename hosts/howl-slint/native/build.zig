const std = @import("std");

const Profile = enum { local, sessions };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const profile = b.option(Profile, "profile", "ABI set: local Instance or remote Sessions") orelse .local;
    switch (profile) {
        .local => {
            const instance = b.dependency("howl_instance", .{ .target = target, .optimize = optimize });
            b.installArtifact(instance.artifact("howl_instance_native"));
            b.installArtifact(instance.artifact("howl_vt_native"));
        },
        .sessions => {
            const render = b.lazyDependency("server_client_render", .{ .target = target, .optimize = optimize }) orelse return;
            // This composite exports Client and Client Render, plus their exact headers.
            b.installArtifact(render.artifact("howl_sessions_native"));
            b.step("test", "Qualify the pinned remote Sessions ABI set").dependOn(&render.builder.top_level_steps.get("test").?.step);
        },
    }
}
