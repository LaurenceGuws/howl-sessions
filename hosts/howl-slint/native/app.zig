//! Static mobile host root; the published composition still owns every ABI.
const std = @import("std");
const composition = @import("composition");

comptime {
    // zig-audit: acknowledge discard
    // reason: Force the unchanged published composition and all its C exports into this artifact.
    _ = composition.hsr_abi_version;
}

/// Preserve safety panics without importing desktop process/debug I/O on iOS.
pub const panic = std.debug.FullPanic(appPanic);

fn appPanic(message: []const u8, trace_address: ?usize) noreturn {
    // zig-audit: acknowledge discard
    // reason: The OS crash report owns stack inspection; this boundary emits the bounded cause and traps.
    _ = trace_address;
    const prefix = "Howl native panic: ";
    // zig-audit: acknowledge discard
    // reason: Best-effort fatal diagnostics cannot recover from a stderr failure.
    _ = std.c.write(2, prefix.ptr, prefix.len);
    // zig-audit: acknowledge discard
    // reason: Best-effort fatal diagnostics cannot recover from a stderr failure.
    _ = std.c.write(2, message.ptr, @min(message.len, 1024));
    // zig-audit: acknowledge discard
    // reason: Best-effort fatal diagnostics cannot recover from a stderr failure.
    _ = std.c.write(2, "\n", 1);
    @trap();
}
