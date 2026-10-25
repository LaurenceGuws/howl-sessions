//! One exact native product composition; do not link two independently built
//! client instances and reinterpret their opaque observation handles.
const std = @import("std");
const client_abi = @import("server_client_abi");
const bridge = @import("server_client_render_native");
const c = bridge.c;
const Status = bridge.Status;
const heap = std.heap.c_allocator;

comptime {
    // Pull the exact Client ABI exports into this artifact.
    // zig-audit: acknowledge discard
    // reason: This static reference links the exact Client exports in one artifact.
    _ = client_abi.hsc_abi_version;
}

// zig-audit: acknowledge anyopaque
// reason: C opaque handles never expose the private allocation layout.
fn renderer(raw: *anyopaque) *bridge.Renderer {
    // zig-audit: acknowledge ptr_cast
    // reason: Only this library creates the matching private owner.
    // zig-audit: acknowledge align_cast
    // reason: The original owner allocation retains native alignment.
    return @ptrCast(@alignCast(raw));
}
// zig-audit: acknowledge anyopaque
// reason: The C frame lease hides storage layout from callers.
fn frame(raw: *anyopaque) *bridge.Frame {
    // zig-audit: acknowledge ptr_cast
    // reason: Only the bridge creates matching private frames.
    // zig-audit: acknowledge align_cast
    // reason: Original frame allocation retains native alignment.
    return @ptrCast(@alignCast(raw));
}
// zig-audit: acknowledge anyerror
// reason: Every internal error is mapped to a closed native status set.
fn failure(err: anyerror) u32 {
    return switch (err) {
        error.OutOfMemory => @backingInt(Status.out_of_memory),
        error.Busy => @backingInt(Status.busy),
        error.UnsupportedImages => @backingInt(Status.unsupported_images),
        error.ResourceLimit, error.CommandLimit, error.PixelLimit, error.ImageLimit => @backingInt(Status.resource_limit),
        error.InvalidArgument => @backingInt(Status.invalid_argument),
        else => @backingInt(Status.render_failed),
    };
}
/// Reports the composed renderer ABI identity.
pub export fn hsr_abi_version() u32 {
    return bridge.abi_version;
}
fn path(value: bridge.Bytes) ?[]const u8 {
    if (value.len == 0 or value.len > bridge.maximum_font_path_bytes) return null;
    const ptr = value.data;
    if (ptr == null) return null;
    return ptr[0..value.len];
}
/// Creates one font-backed canonical terminal renderer.
// zig-audit: acknowledge anyopaque
// reason: This opaque output names a renderer owned by the composed library.
pub export fn hsr_create(version: u32, config: ?*const bridge.Config, out: ?*?*anyopaque) u32 {
    if (version != bridge.abi_version) return @backingInt(Status.version_mismatch);
    const slot = out orelse return @backingInt(Status.invalid_argument);
    if (slot.* != null) return @backingInt(Status.invalid_argument);
    const input = config orelse return @backingInt(Status.invalid_argument);
    if (input.reserved != 0 or input.fallback_count > bridge.maximum_fallbacks or
        (input.fallback_count != 0 and input.fallbacks == null))
        return @backingInt(Status.invalid_argument);
    const primary = path(input.primary) orelse return @backingInt(Status.invalid_argument);
    var fallback_storage: [bridge.maximum_fallbacks][]const u8 = undefined;
    for (0..input.fallback_count) |index| {
        fallback_storage[index] = path(input.fallbacks[index]) orelse return @backingInt(Status.invalid_argument);
    }
    const value = bridge.create(heap, primary, fallback_storage[0..input.fallback_count], input.pixel_size) catch |err| return failure(err);
    // zig-audit: acknowledge ptr_cast
    // reason: This pointer denotes the freshly allocated matching private renderer handle.
    slot.* = @ptrCast(value);
    return @backingInt(Status.ok);
}
/// Destroys an idle renderer; BUSY preserves its owning slot.
// zig-audit: acknowledge anyopaque
// reason: Only the defining C ABI releases this native handle.
pub export fn hsr_try_destroy(out: ?*?*anyopaque) u32 {
    const slot = out orelse return @backingInt(Status.ok);
    const raw = slot.* orelse return @backingInt(Status.ok);
    bridge.destroy(renderer(raw)) catch return @backingInt(Status.busy);
    slot.* = null;
    return @backingInt(Status.ok);
}
/// Returns font-derived terminal cell pixels.
// zig-audit: acknowledge anyopaque
// reason: This const borrow never exposes renderer allocation layout.
pub export fn hsr_cell_size(raw: ?*const anyopaque, out: ?*c.hrc_cell_size) u32 {
    const result = out orelse return @backingInt(Status.invalid_argument);
    result.* = std.mem.zeroes(c.hrc_cell_size);
    const ptr = raw orelse return @backingInt(Status.invalid_argument);
    // zig-audit: acknowledge const_cast
    // reason: An immutable C view borrows the owner; the query cannot mutate it.
    const value = bridge.cellSize(renderer(@constCast(ptr)));
    result.* = .{ .width = value.width, .height = value.height, .reserved = 0 };
    return @backingInt(Status.ok);
}
/// Captures an immutable frame while synchronously borrowing one Client snapshot.
// zig-audit: acknowledge anyopaque
// reason: Renderer C owner retains only private storage from this library.
// zig-audit: acknowledge anyopaque
// reason: Borrowed snapshot is produced by the same exact Client module.
// zig-audit: acknowledge anyopaque
// reason: Frame output is allocated only by this compiled bridge.
pub export fn hsr_capture(raw: ?*anyopaque, snapshot: ?*const anyopaque, residencies: ?[*]const c.hrc_residency, count: usize, out: ?*?*anyopaque) u32 {
    const slot = out orelse return @backingInt(Status.invalid_argument);
    if (slot.* != null) return @backingInt(Status.invalid_argument);
    const ptr = raw orelse return @backingInt(Status.invalid_argument);
    const source = snapshot orelse return @backingInt(Status.invalid_argument);
    if (count > c.HRC_MAX_RESIDENCIES or (count != 0 and residencies == null)) return @backingInt(Status.invalid_argument);
    const current: []const c.hrc_residency = if (count == 0) &.{} else residencies.?[0..count];
    // zig-audit: acknowledge ptr_cast
    // reason: Snapshot originates in this exact compiled Client ABI; independently built handles are forbidden.
    // zig-audit: acknowledge align_cast
    // reason: Client's own opaque snapshot allocation preserves View alignment.
    const view: *const bridge.View.Snapshot = @ptrCast(@alignCast(source));
    const value = bridge.capture(renderer(ptr), view, current) catch |err| return failure(err);
    // zig-audit: acknowledge ptr_cast
    // reason: This immutable frame was fully allocated by the matching bridge owner.
    slot.* = @ptrCast(value);
    return @backingInt(Status.ok);
}
/// Borrows copied canonical frame commands, uploads and removals.
// zig-audit: acknowledge anyopaque
// reason: Frame pointer borrows only matching private immutable storage.
pub export fn hsr_frame_read(raw: ?*const anyopaque, out: ?*c.hrc_frame_view) u32 {
    const result = out orelse return @backingInt(Status.invalid_argument);
    result.* = std.mem.zeroes(c.hrc_frame_view);
    const value = raw orelse return @backingInt(Status.invalid_argument);
    // zig-audit: acknowledge const_cast
    // reason: The read only borrows immutable frame storage.
    result.* = bridge.read(frame(@constCast(value)));
    return @backingInt(Status.ok);
}
/// Releases the frame after all host rendering uses complete.
// zig-audit: acknowledge anyopaque
// reason: C frame storage is private and cleared only by its creator.
pub export fn hsr_frame_release(out: ?*?*anyopaque) void {
    const slot = out orelse return;
    const raw = slot.* orelse return;
    slot.* = null;
    bridge.release(frame(raw));
}
