//! Native ownership for one transported snapshot -> canonical Render frame.
//! No Server I/O, source cache, Flutter scheduler or second terminal model.
const std = @import("std");
const render = @import("server_client_render");
const projection = @import("howl_render_native");
const types = @import("render_abi_types");

/// Native frame records owned by canonical Howl Render.
pub const c = projection.c;
/// ABI version translated directly from the adapter's C header.
pub const abi_version = types.HSR_ABI_VERSION;
/// The exact compiled Server Client view.
pub const View = render.View;
/// Canonical Text font path admission ceiling.
pub const maximum_font_path_bytes = render.text.max_font_path_bytes;
/// Maximum canonical Text fallback faces.
pub const maximum_fallbacks = render.text.max_fallbacks;
/// Constructor byte span from the single module-owned C header.
pub const Bytes = types.hsr_bytes;
/// Constructor input from the single module-owned C header.
pub const Config = types.hsr_config;
/// Public status vocabulary, its numeric values translated from that header.
pub const Status = enum(u32) {
    ok = types.HSR_OK,
    invalid_argument = types.HSR_INVALID_ARGUMENT,
    version_mismatch = types.HSR_VERSION_MISMATCH,
    out_of_memory = types.HSR_OUT_OF_MEMORY,
    resource_limit = types.HSR_RESOURCE_LIMIT,
    busy = types.HSR_BUSY,
    unsupported_images = types.HSR_UNSUPPORTED_IMAGES,
    render_failed = types.HSR_RENDER_FAILED,
};
const atlas_width: u16 = 1024;
const atlas_height: u16 = 1024;
const command_limit: usize = render.limits.maximum_frame_commands;
const pixels_limit: usize = @as(usize, atlas_width) * atlas_height * 5;

/// Complete bridge constructor/capture error set.
pub const Error = render.text.InitError || render.InitError || render.Error ||
    projection.Error || error{ InvalidArgument, ResourceLimit, Busy, UnsupportedImages };
/// Owns one font, Renderer, finite scratch and at most one frame.
pub const Renderer = struct {
    allocator: std.mem.Allocator,
    font: *render.text.FontSet,
    renderer: *render.Renderer,
    cell: render.Size,
    commands: []render.Command,
    pixels: []u8,
    frame_open: bool = false,
};
/// Immutable C records copied from one canonical Render frame.
pub const Frame = struct {
    allocator: std.mem.Allocator,
    parent: *Renderer,
    info: c.hrc_frame_info,
    commands: []c.hrc_command,
    pixels: []u8,
    uploads: [render.maximum_frame_resources]c.hrc_upload = undefined,
    removals: [render.maximum_frame_resources]c.hrc_removal = undefined,
};

/// Construct one font and one renderer; all pixel/command budgets are finite.
pub fn create(allocator: std.mem.Allocator, path: []const u8, fallbacks: []const []const u8, pixel_size: u16) Error!*Renderer {
    if (pixel_size == 0 or path.len == 0 or path.len > maximum_font_path_bytes or
        std.mem.indexOfScalar(u8, path, 0) != null or fallbacks.len > render.text.max_fallbacks) return error.InvalidArgument;
    for (fallbacks) |candidate| {
        if (candidate.len == 0 or candidate.len > maximum_font_path_bytes or
            std.mem.indexOfScalar(u8, candidate, 0) != null) return error.InvalidArgument;
    }
    const font = try render.text.FontSet.init(allocator, .{
        .primary = path,
        .fallbacks = fallbacks,
        .size = .{ .pixels = pixel_size },
    });
    errdefer font.deinit();
    const faces = render.FontFaces.single(font);
    const metrics = faces.metrics();
    const cell: render.Size = .{ .width = metrics.advance_width, .height = metrics.line_height };
    const renderer = try render.initPrivate(allocator, faces, .{
        .cell_size = cell,
        .box_drawing = .{ .dpi_x = .{ .numerator = 96, .denominator = 1 }, .dpi_y = .{ .numerator = 96, .denominator = 1 } },
        .shape_cache = .{
            .entry_capacity = 4096,
            .scalar_capacity = 16384,
            .glyph_capacity = 16384,
            .max_sequence_scalars = 64,
        },
        .atlas = .{
            .width = atlas_width,
            .height = atlas_height,
            .gap = 2,
            .entry_capacity = 8192,
        },
        .shaped_capacity = 4096,
        .raster_bytes = 4 * 1024 * 1024,
        .command_capacity = 128,
        .command_limit = command_limit,
    });
    errdefer render.deinit(renderer);
    const commands = try allocator.alloc(render.Command, 128);
    errdefer allocator.free(commands);
    const pixels = try allocator.alloc(u8, @as(usize, atlas_width) * atlas_height);
    errdefer allocator.free(pixels);
    const owner = try allocator.create(Renderer);
    owner.* = .{
        .allocator = allocator,
        .font = font,
        .renderer = renderer,
        .cell = cell,
        .commands = commands,
        .pixels = pixels,
    };
    return owner;
}
/// Destroy only after the last frame has been released.
pub fn destroy(value: *Renderer) error{Busy}!void {
    if (value.frame_open) return error.Busy;
    const allocator = value.allocator;
    render.deinit(value.renderer);
    allocator.free(value.commands);
    allocator.free(value.pixels);
    value.font.deinit();
    allocator.destroy(value);
}
/// Returns the fixed font-derived cell extent.
pub fn cellSize(value: *const Renderer) render.Size {
    return value.cell;
}
fn residencies(values: []const c.hrc_residency, output: *[render.maximum_frame_resources]render.Residency) Error![]const render.Residency {
    if (values.len > output.len) return error.ResourceLimit;
    for (values, 0..) |value, index| {
        if (value.generation == 0 or value.width == 0 or value.height == 0 or
            !std.mem.allEqual(u8, &value._reserved, 0)) return error.InvalidArgument;
        const format: render.ResourceFormat = switch (value.format) {
            c.HRC_ALPHA8 => .alpha8,
            c.HRC_RGBA8 => .rgba8,
            else => return error.InvalidArgument,
        };
        output[index] = .{
            .resource = .{
                .resource = render.ResourceId.init(value.resource) catch return error.InvalidArgument,
                .generation = @fromBackingInt(value.generation),
            },
            .format = format,
            .size = .{ .width = value.width, .height = value.height },
        };
    }
    const result = output[0..values.len];
    render.validateResidencies(result) catch return error.InvalidArgument;
    return result;
}
fn capacity(current: usize, needed: usize, maximum: usize) Error!usize {
    if (needed > maximum) return error.ResourceLimit;
    const doubled = std.math.mul(usize, current, 2) catch maximum;
    return @min(maximum, @max(needed, doubled));
}
fn growCommands(value: *Renderer) Error!void {
    if (value.commands.len == command_limit) return error.CommandLimit;
    const next = try value.allocator.alloc(render.Command, try capacity(value.commands.len, value.commands.len + 1, command_limit));
    value.allocator.free(value.commands);
    value.commands = next;
}
fn growPixels(value: *Renderer, residency: []const render.Residency) Error!void {
    const needed = try render.framePixelBytes(value.renderer, residency);
    if (needed <= value.pixels.len) return error.PixelLimit;
    const next = try value.allocator.alloc(u8, try capacity(value.pixels.len, needed, pixels_limit));
    value.allocator.free(value.pixels);
    value.pixels = next;
}
/// Capture copies all Render records and atlas bytes before releasing source.
pub fn capture(value: *Renderer, snapshot: *const View.Snapshot, backend: []const c.hrc_residency) Error!*Frame {
    if (value.frame_open) return error.Busy;
    const images = View.graphics(snapshot);
    if (images.images.len != 0 or images.placements.len != 0) return error.UnsupportedImages;
    var backend_storage: [render.maximum_frame_resources]render.Residency = undefined;
    const current = try residencies(backend, &backend_storage);
    const high_water = render.usage(value.renderer).resource_high_water;
    for (current) |entry| {
        if (@backingInt(entry.resource.resource) > high_water) return error.InvalidArgument;
    }
    const geometry = View.metadata(snapshot);
    if (geometry.rows == 0 or geometry.columns == 0 or
        geometry.rows > render.limits.maximum_rows or geometry.columns > render.limits.maximum_columns)
        return error.ResourceLimit;
    const width = std.math.mul(usize, geometry.columns, value.cell.width) catch return error.ResourceLimit;
    const height = std.math.mul(usize, geometry.rows, value.cell.height) catch return error.ResourceLimit;
    if (width > std.math.maxInt(u16) or height > std.math.maxInt(u16)) return error.ResourceLimit;

    try render.update(value.renderer, snapshot);
    var uploads: [render.maximum_frame_resources]render.FrameResourceUpload = undefined;
    var removals: [render.maximum_frame_resources]render.ResourceRef = undefined;
    const rendered = while (true) {
        const result = render.frame(value.renderer, current, .{
            .commands = value.commands,
            .uploads = &uploads,
            .removals = &removals,
            .pixels = value.pixels,
        }) catch |err| switch (err) {
            error.CommandLimit => {
                try growCommands(value);
                continue;
            },
            error.PixelLimit => {
                try growPixels(value, current);
                continue;
            },
            else => return err,
        };
        break result;
    };
    const owned = try value.allocator.create(Frame);
    errdefer value.allocator.destroy(owned);
    const commands = try value.allocator.alloc(c.hrc_command, rendered.commands.len);
    errdefer value.allocator.free(commands);
    const pixels = try value.allocator.dupe(u8, rendered.pixels);
    errdefer value.allocator.free(pixels);
    // zig-audit: acknowledge discard
    // reason: Complete immutable output is retained by the frame until explicit release.
    _ = try projection.commands(rendered.commands, commands);
    owned.* = .{
        .allocator = value.allocator,
        .parent = value,
        .info = .{
            .revision = rendered.revision,
            .content_revision = rendered.content_revision,
            .terminal_revision = geometry.revision,
            .command_count = @intCast(rendered.commands.len),
            .content_command_count = @intCast(rendered.content_command_count),
            .upload_count = @intCast(rendered.uploads.len),
            .removal_count = @intCast(rendered.removals.len),
            .history_offset = geometry.history_offset,
            .history_count = geometry.history_count,
            .history_row_base = geometry.history_row_base,
            .background_rgba = projection.background(rendered.commands, .{ .width = @intCast(width), .height = @intCast(height) }),
            .surface_width = @intCast(width),
            .surface_height = @intCast(height),
            .cell_width = value.cell.width,
            .cell_height = value.cell.height,
            .alternate_screen = @intFromBool(geometry.alternate_screen),
            .reserved = @splat(0),
        },
        .commands = commands,
        .pixels = pixels,
    };
    // zig-audit: acknowledge discard
    // reason: All pixel spans were checked before immutable frame publication.
    _ = try projection.uploads(rendered.uploads, pixels, &owned.uploads);
    // zig-audit: acknowledge discard
    // reason: The exact complete removal records are copied before frame publication.
    _ = try projection.removals(rendered.removals, &owned.removals);
    value.frame_open = true;
    return owned;
}
/// Borrow only the immutable records of a live frame.
pub fn read(value: *const Frame) c.hrc_frame_view {
    return .{
        .info = value.info,
        .commands = if (value.commands.len == 0) null else value.commands.ptr,
        .uploads = if (value.info.upload_count == 0) null else &value.uploads,
        .removals = if (value.info.removal_count == 0) null else &value.removals,
    };
}
/// Ends the frame lease before its parent can capture again.
pub fn release(value: *Frame) void {
    const allocator = value.allocator;
    const parent = value.parent;
    allocator.free(value.pixels);
    allocator.free(value.commands);
    allocator.destroy(value);
    parent.frame_open = false;
}

test "native C records retain the Render owner schema" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(c.hrc_command));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(c.hrc_resource));
}
