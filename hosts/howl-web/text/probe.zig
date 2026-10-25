//! Executes the actual memory-font owner, shaper and rasterizer for target parity.
const std = @import("std");
const text = @import("howl_text");
// Safety violations trap instead of pulling filesystem-backed stack tracing into the host.
/// Traps unexpected Zig failures in the Wasm text proof.
pub const panic = std.debug.FullPanic(trapPanic);
fn trapPanic(_: []const u8, _: ?usize) noreturn {
    @trap();
}
var incoming: [16 * 1024 * 1024]u8 = undefined;
var heap: [20 * 1024 * 1024]u8 = undefined;
var report: [65536]u8 = undefined;
var report_len: usize = 0;
var masks: [1024 * 1024]u8 = undefined;
var masks_len: usize = 0;
var failure: []const u8 = "";
const GlyphProof = struct {
    glyph: text.Glyph,
    width: u16,
    height: u16,
    left: i16,
    top: i16,
    offset: usize,
    length: usize,
};
export fn font_input() usize {
    return @intFromPtr(&incoming);
}
export fn font_capacity() usize {
    return incoming.len;
}
export fn result_ptr() usize {
    return @intFromPtr(&report);
}
export fn result_len() usize {
    return report_len;
}
export fn raster_ptr() usize {
    return @intFromPtr(&masks);
}
export fn raster_len() usize {
    return masks_len;
}
export fn error_ptr() usize {
    return @intFromPtr(failure.ptr);
}
export fn error_len() usize {
    return failure.len;
}
export fn run(length: u32) u32 {
    failure = "";
    report_len = 0;
    masks_len = 0;
    if (length > incoming.len) {
        failure = "InputTooLarge";
        return 0;
    }
    execute(length) catch |err| {
        failure = @errorName(err);
        return 0;
    };
    return 1;
}
fn execute(length: u32) !void {
    var memory = std.heap.FixedBufferAllocator.init(&heap);
    const allocator = memory.allocator();
    const set = try text.FontSet.initMemory(allocator, .{ .primary = incoming[0..length], .size = .{ .pixels = 28 } });
    defer set.deinit();
    // Deliberately destroy the caller's font buffer. The owner must not borrow it.
    @memset(incoming[0..length], 0xa5);
    const buffer = try text.ShapeBuffer.init(allocator, 64);
    defer buffer.deinit();
    var glyphs: [64]text.Glyph = undefined;
    var proofs: [64]GlyphProof = undefined;
    const shaped = try set.shape(buffer, .{
        .codepoints = &.{ 'f', 'f', 'i', ' ', 'e', 0x301, ' ', 0x3bb },
        .clusters = &.{ 10, 11, 12, 13, 14, 14, 15, 16 },
    }, &glyphs);
    for (shaped.glyphs, 0..) |glyph, index| {
        var raster = try set.rasterize(allocator, shaped.face_index, glyph.id);
        defer raster.deinit();
        if (raster.pixels.len > masks.len - masks_len) return error.MaskBudget;
        @memcpy(masks[masks_len..][0..raster.pixels.len], raster.pixels);
        proofs[index] = .{ .glyph = glyph, .width = raster.width, .height = raster.height, .left = raster.left, .top = raster.top, .offset = masks_len, .length = raster.pixels.len };
        masks_len += raster.pixels.len;
    }
    var writer = std.Io.Writer.fixed(&report);
    try std.json.Stringify.value(.{
        .schema = "howl.text-target-proof/v1",
        .caller_buffer_overwritten = true,
        .metrics = set.metrics(),
        .face_index = shaped.face_index,
        .glyphs = proofs[0..shaped.glyphs.len],
        .mask_bytes = masks_len,
    }, .{}, &writer);
    report_len = writer.end;
}

extern fn jump_proof_c() c_uint;
export fn jump_probe() u32 {
    return jump_proof_c();
}
