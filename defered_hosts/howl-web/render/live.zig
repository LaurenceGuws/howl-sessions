//! Live browser renderer: framed Howl snapshot bytes -> shared view/text/terminal-renderer state.
const std = @import("std");
const client = @import("server_client").terminal;
const terminal = @import("server_client_render");
const render = terminal;
const render_native = @import("howl_render_native");
const text = render.text;
const p = client.protocol;

/// Traps unexpected Zig failures at the Wasm host boundary.
pub const panic = std.debug.FullPanic(trapPanic);
fn trapPanic(_: []const u8, _: ?usize) noreturn {
    @trap();
}

const command_capacity = render.limits.maximum_frame_commands;
const command_record_bytes: usize = 64;
const command_wire_bytes: usize = command_capacity * command_record_bytes;
const metadata_capacity: usize = 32 * 1024 * 1024;
const atlas_bytes = 1024 * 1024;
const maximum_terminal_images: usize = terminal.maximum_external_images;
const residency_capacity = terminal.maximum_frame_resources;

comptime {
    if (render_native.c.HRC_NATIVE_VERSION != 1 or @sizeOf(render_native.CommandInfo) != 64 or
        render_native.c.HRC_SOLID != 0 or render_native.c.HRC_ALPHA_MASK != 1 or render_native.c.HRC_RGBA != 2)
        @compileError("Web frame packing requires the reviewed Render native vocabulary");
    if (maximum_terminal_images != 7)
        @compileError("Web terminal image bound drifted from the portable client contract");
    if (command_wire_bytes >= metadata_capacity)
        @compileError("binary command lane exceeds Web metadata storage");
}

var font_input: [8 * 1024 * 1024]u8 = undefined;
var fallback_font_input: [2 * 1024 * 1024]u8 = undefined;
var symbol_font_input: [3 * 1024 * 1024]u8 = undefined;
var snapshot_input: [p.maximum_observation_bytes]u8 = undefined;
var persistent_heap: [64 * 1024 * 1024]u8 = undefined;
var transient_heap: [20 * 1024 * 1024]u8 = undefined;
var metadata: [metadata_capacity]u8 = undefined;
var metadata_used: usize = 0;
var command_wire_count: usize = 0;
var projections: [2][65536]u8 = undefined;
var projection_lengths: [2]usize = @splat(0);
var projection_truncated: [2]bool = @splat(false);
var published_projection: usize = 0;
var pending_projection: usize = 1;
var pixels: [atlas_bytes]u8 = undefined;
var pixels_used: usize = 0;
var frame_uploads: [residency_capacity]terminal.FrameResourceUpload = undefined;
var frame_removals: [residency_capacity]terminal.ResourceRef = undefined;
var frame_commands: [command_capacity]terminal.Command = undefined;
var accepted_residency: [residency_capacity]terminal.Residency = undefined;
var accepted_residency_count: usize = 0;
var pending_residency: [residency_capacity]terminal.Residency = undefined;
var pending_residency_count: usize = 0;
var missing_external_storage: [maximum_terminal_images]terminal.FrameExternalResource = undefined;
var missing_external: ?terminal.FrameExternalResource = null;
var image_bindings: [maximum_terminal_images]ImageBinding = undefined;
var image_binding_count: usize = 0;
var missing_image_binding: ?ImageBinding = null;
var pending_ack = false;
var failure: []const u8 = "";

var persistent = std.heap.FixedBufferAllocator.init(&persistent_heap);
var transient = std.heap.FixedBufferAllocator.init(&transient_heap);
var fonts: ?*text.FontSet = null;
var terminal_renderer: ?*terminal.Renderer = null;
var renderer_ready = false;
var cell_size: terminal.Size = .{ .width = 1, .height = 1 };
var surface: terminal.Size = .{ .width = 1, .height = 1 };
var rendered: u64 = 0;
const FrameFormat = enum(u32) { v2 = 2, v3 = 3, v4 = 4 };
// Boot in the last deployed format so an old host may safely consume a newer
// renderer. A v3-aware host opts in before it opens its observation streams.
var frame_format: FrameFormat = .v2;

const ImageBinding = terminal.ExternalImageBinding;

const PendingExternal = struct {
    binding: ImageBinding,
    external: terminal.FrameExternalResource,
};

const RenderResult = enum {
    frame,
    external,
};

export fn rv_font_ptr() usize {
    return @intFromPtr(&font_input);
}
export fn rv_font_capacity() usize {
    return font_input.len;
}
export fn rv_fallback_font_ptr() usize {
    return @intFromPtr(&fallback_font_input);
}
export fn rv_fallback_font_capacity() usize {
    return fallback_font_input.len;
}
export fn rv_symbol_font_ptr() usize {
    return @intFromPtr(&symbol_font_input);
}
export fn rv_symbol_font_capacity() usize {
    return symbol_font_input.len;
}
export fn rv_snapshot_ptr() usize {
    return @intFromPtr(&snapshot_input);
}
export fn rv_snapshot_capacity() usize {
    return snapshot_input.len;
}
export fn rv_frame_ptr() usize {
    return @intFromPtr(&metadata) + if (frame_format == .v4) command_wire_bytes else 0;
}
export fn rv_frame_len() usize {
    return metadata_used;
}
export fn rv_commands_ptr() usize {
    return @intFromPtr(&metadata);
}
export fn rv_commands_count() usize {
    return command_wire_count;
}
export fn rv_commands_stride() usize {
    return command_record_bytes;
}
export fn rv_text_ptr() usize {
    return @intFromPtr(&projections[published_projection]);
}
export fn rv_text_len() usize {
    return projection_lengths[published_projection];
}
export fn rv_text_truncated() u32 {
    return @intFromBool(projection_truncated[published_projection]);
}
export fn rv_pixels_ptr() usize {
    return @intFromPtr(&pixels);
}
export fn rv_pixels_len() usize {
    return pixels_used;
}
export fn rv_error_ptr() usize {
    return @intFromPtr(failure.ptr);
}
export fn rv_error_len() usize {
    return failure.len;
}
export fn rv_render_count() u64 {
    return rendered;
}
export fn rv_frame_format() u32 {
    return @backingInt(frame_format);
}
export fn rv_set_frame_format(value: u32) u32 {
    if (pending_ack or rendered != 0) return 0;
    frame_format = switch (value) {
        2 => .v2,
        3 => .v3,
        4 => .v4,
        else => return 0,
    };
    return 1;
}
export fn rv_ready() u32 {
    return @intFromBool(renderer_ready);
}
export fn rv_missing_external() u32 {
    return @intFromBool(missing_external != null);
}
export fn rv_missing_resource() u64 {
    return if (missing_external) |value| @backingInt(value.resource.resource) else 0;
}
export fn rv_missing_generation() u64 {
    return if (missing_external) |value| @backingInt(value.resource.generation) else 0;
}
export fn rv_missing_format() u32 {
    return if (missing_external) |value| @backingInt(value.format) else 0;
}
export fn rv_missing_width() u32 {
    return if (missing_external) |value| value.size.width else 0;
}
export fn rv_missing_height() u32 {
    return if (missing_external) |value| value.size.height else 0;
}
export fn rv_missing_stride() usize {
    return if (missing_external) |value| value.stride else 0;
}
export fn rv_missing_image_id() u32 {
    return if (missing_external != null and missing_image_binding != null)
        missing_image_binding.?.image_id
    else
        0;
}
export fn rv_missing_image_generation() u64 {
    return if (missing_external != null and missing_image_binding != null)
        missing_image_binding.?.generation
    else
        0;
}

fn fail(message: []const u8) u32 {
    failure = message;
    metadata_used = 0;
    command_wire_count = 0;
    pixels_used = 0;
    return 0;
}

export fn rv_init(font_length: usize, fallback_font_length: usize, symbol_font_length: usize, font_pixels: u32) u32 {
    return initRenderer(font_length, fallback_font_length, symbol_font_length, font_pixels, null);
}

/// Initializes one explicit physical-pixel presentation lattice.
///
/// Browser HiDPI hosts rasterize the font at a physical size while retaining
/// the maintained terminal cell geometry. Keeping those inputs separate avoids
/// letting size-specific FreeType hinting silently change columns or line
/// spacing when DPR changes.
export fn rv_init_presentation(
    font_length: usize,
    fallback_font_length: usize,
    symbol_font_length: usize,
    font_pixels: u32,
    cell_width: u32,
    line_height: u32,
) u32 {
    if (cell_width == 0 or cell_width > std.math.maxInt(u16) or
        line_height == 0 or line_height > std.math.maxInt(u16)) return 0;
    return initRenderer(font_length, fallback_font_length, symbol_font_length, font_pixels, .{
        .width = @intCast(cell_width),
        .height = @intCast(line_height),
    });
}

fn initRenderer(
    font_length: usize,
    fallback_font_length: usize,
    symbol_font_length: usize,
    font_pixels: u32,
    requested_cell: ?terminal.Size,
) u32 {
    if (renderer_ready or font_pixels < 6 or font_pixels > 64 or font_length == 0 or font_length > font_input.len or
        fallback_font_length == 0 or fallback_font_length > fallback_font_input.len or
        symbol_font_length == 0 or symbol_font_length > symbol_font_input.len) return 0;
    persistent.reset();
    transient.reset();
    accepted_residency_count = 0;
    pending_residency_count = 0;
    missing_external = null;
    image_binding_count = 0;
    missing_image_binding = null;
    pending_ack = false;
    rendered = 0;
    failure = "";
    metadata_used = 0;
    command_wire_count = 0;
    projection_lengths = @splat(0);
    projection_truncated = @splat(false);
    published_projection = 0;
    pending_projection = 1;
    pixels_used = 0;

    const allocator = persistent.allocator();
    const fallback_sources = [_][]const u8{
        fallback_font_input[0..fallback_font_length],
        symbol_font_input[0..symbol_font_length],
    };
    const new_fonts = text.FontSet.initMemory(allocator, .{
        .primary = font_input[0..font_length],
        .fallbacks = &fallback_sources,
        .size = .{ .pixels = @intCast(font_pixels) },
    }) catch |err| return fail(@errorName(err));
    errdefer new_fonts.deinit();
    @memset(font_input[0..font_length], 0xa5);
    @memset(fallback_font_input[0..fallback_font_length], 0x5a);
    @memset(symbol_font_input[0..symbol_font_length], 0x3c);
    const metrics = new_fonts.metrics();
    const presentation_cell = requested_cell orelse terminal.Size{
        .width = metrics.advance_width,
        .height = metrics.line_height,
    };
    const new_renderer = terminal.initPrivate(allocator, terminal.FontFaces.single(new_fonts), .{
        .cell_size = presentation_cell,
        .box_drawing = .{
            .dpi_x = .{ .numerator = 96, .denominator = 1 },
            .dpi_y = .{ .numerator = 96, .denominator = 1 },
        },
        .shape_cache = .{
            .entry_capacity = 4096,
            .scalar_capacity = 32768,
            .glyph_capacity = 32768,
            .max_sequence_scalars = 64,
        },
        .atlas = .{ .width = 1024, .height = 1024, .entry_capacity = 4096 },
        .shaped_capacity = 256,
        .raster_bytes = 256 * 1024,
        .command_capacity = command_capacity,
    }) catch |err| return fail(@errorName(err));
    errdefer terminal.deinit(new_renderer);

    fonts = new_fonts;
    terminal_renderer = new_renderer;
    cell_size = presentation_cell;
    renderer_ready = true;
    return 1;
}

export fn rv_reset() u32 {
    if (renderer_ready) {
        terminal.deinit(terminal_renderer.?);
        fonts.?.deinit();
    }
    fonts = null;
    terminal_renderer = null;
    renderer_ready = false;
    persistent.reset();
    transient.reset();
    accepted_residency_count = 0;
    pending_residency_count = 0;
    missing_external = null;
    image_binding_count = 0;
    missing_image_binding = null;
    pending_ack = false;
    metadata_used = 0;
    command_wire_count = 0;
    projection_lengths = @splat(0);
    projection_truncated = @splat(false);
    published_projection = 0;
    pending_projection = 1;
    pixels_used = 0;
    rendered = 0;
    failure = "";
    return 1;
}

export fn rv_render(snapshot_length: usize) u32 {
    if (!renderer_ready or pending_ack or snapshot_length == 0 or snapshot_length > snapshot_input.len)
        return 0;
    failure = "";
    metadata_used = 0;
    command_wire_count = 0;
    pixels_used = 0;
    missing_external = null;
    missing_image_binding = null;
    const result = renderSnapshot(snapshot_input[0..snapshot_length]) catch |err| return fail(@errorName(err));
    return switch (result) {
        .frame => 1,
        .external => 2,
    };
}

fn renderSnapshot(bytes: []const u8) !RenderResult {
    transient.reset();
    defer transient.reset();
    const allocator = transient.allocator();
    var rich = try client.rich.decodeFrames(allocator, bytes);
    defer rich.deinit();
    const view = try client.view.project(allocator, &rich);
    defer client.view.deinit(view);
    const begin = client.view.begin(view);
    const next_render = std.math.add(u64, rendered, 1) catch return error.RenderRevisionOverflow;
    try updateRenderer(view);
    surface = .{
        .width = std.math.mul(u16, begin.terminal.columns, cell_size.width) catch return error.SurfaceOverflow,
        .height = std.math.mul(u16, begin.terminal.rows, cell_size.height) catch return error.SurfaceOverflow,
    };
    const frame = terminal.frame(terminal_renderer.?, accepted_residency[0..accepted_residency_count], .{
        .uploads = &frame_uploads,
        .removals = &frame_removals,
        .commands = &frame_commands,
        .pixels = &pixels,
    }) catch |err| switch (err) {
        error.MissingExternalResource => {
            try prepareMissingExternal();
            return .external;
        },
        else => return err,
    };
    pixels_used = frame.pixels.len;
    try collectPendingResidency(frame.commands);
    pending_projection = if (published_projection == 0) 1 else 0;
    const text_projection = client.view.writeVisibleText(view, &projections[pending_projection]);
    projection_lengths[pending_projection] = text_projection.bytes_written;
    projection_truncated[pending_projection] = text_projection.truncated;
    try writeFrame(frame, view, begin.revision, begin.terminal.revision, next_render);
    rendered = next_render;
    pending_ack = true;
    return .frame;
}

/// Installs the exact externally uploaded resource currently requested by
/// `rv_render`. The browser calls this only after its backend resource exists.
export fn rv_accept_external() u32 {
    if (!renderer_ready or pending_ack) return 0;
    const value = missing_external orelse return 0;
    const residency = terminal.Residency{
        .resource = value.resource,
        .format = value.format,
        .size = value.size,
    };
    for (accepted_residency[0..accepted_residency_count]) |*current| {
        if (@backingInt(current.resource.resource) == @backingInt(residency.resource.resource)) {
            current.* = residency;
            missing_external = null;
            missing_image_binding = null;
            return 1;
        }
    }
    if (accepted_residency_count == accepted_residency.len) return 0;
    accepted_residency[accepted_residency_count] = residency;
    accepted_residency_count += 1;
    missing_external = null;
    missing_image_binding = null;
    return 1;
}

fn updateRenderer(view: *const client.view.Snapshot) !void {
    const graphics = client.view.graphics(view);
    if (graphics.images.len > maximum_terminal_images)
        return error.UnsupportedGraphics;
    var candidate: [maximum_terminal_images]ImageBinding = undefined;
    const bindings = terminal.planExternalImageBindings(
        image_bindings[0..image_binding_count],
        terminal.usage(terminal_renderer.?),
        graphics.images,
        &candidate,
    ) catch |err| switch (err) {
        error.ImageLimit => return error.UnsupportedGraphics,
        else => return err,
    };
    try terminal.updateWithImageBindings(terminal_renderer.?, view, bindings);
    @memcpy(image_bindings[0..bindings.len], bindings);
    image_binding_count = bindings.len;
}

fn findImageBindingByResource(
    bindings: []const ImageBinding,
    resource: terminal.ResourceRef,
) ?ImageBinding {
    for (bindings) |binding| {
        if (binding.resource.resource == resource.resource and
            binding.resource.generation == resource.generation)
            return binding;
    }
    return null;
}

fn selectMissingExternal(missing: []const terminal.FrameExternalResource) !PendingExternal {
    if (missing.len == 0 or missing.len > image_binding_count)
        return error.InvalidExternalResource;
    var selected: ?PendingExternal = null;
    for (missing, 0..) |value, index| {
        if (value.format != .rgba8) return error.InvalidExternalResource;
        const binding = findImageBindingByResource(
            image_bindings[0..image_binding_count],
            value.resource,
        ) orelse return error.InvalidExternalResource;
        if (index == 0) selected = .{ .binding = binding, .external = value };
    }
    return selected orelse error.InvalidExternalResource;
}

fn prepareMissingExternal() !void {
    const missing = try terminal.missingExternalResources(
        terminal_renderer.?,
        accepted_residency[0..accepted_residency_count],
        &missing_external_storage,
    );
    const selected = try selectMissingExternal(missing);
    missing_external = selected.external;
    missing_image_binding = selected.binding;
}

export fn rv_ack() u32 {
    if (!renderer_ready or !pending_ack) return 0;
    @memcpy(accepted_residency[0..pending_residency_count], pending_residency[0..pending_residency_count]);
    accepted_residency_count = pending_residency_count;
    pending_residency_count = 0;
    published_projection = pending_projection;
    pending_ack = false;
    return 1;
}

fn exactResourceEqual(a: terminal.ResourceRef, b: terminal.ResourceRef) bool {
    return @backingInt(a.resource) == @backingInt(b.resource) and
        @backingInt(a.generation) == @backingInt(b.generation);
}

fn collectPendingResidency(commands: []const terminal.Command) error{ResidencyLimit}!void {
    pending_residency_count = 0;
    for (commands) |command| {
        const view: ?terminal.ResourceView = switch (command) {
            .solid => null,
            .alpha_mask => |value| value.resource,
            .rgba => |value| value.resource,
        };
        const resource = view orelse continue;
        var seen = false;
        for (pending_residency[0..pending_residency_count]) |entry| {
            if (exactResourceEqual(entry.resource, resource.resource)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        if (pending_residency_count == pending_residency.len) return error.ResidencyLimit;
        pending_residency[pending_residency_count] = .{
            .resource = resource.resource,
            .format = resource.format,
            .size = resource.size,
        };
        pending_residency_count += 1;
    }
}

fn writeFrame(
    frame: terminal.Frame,
    snapshot: *const client.view.Snapshot,
    observation_revision: u64,
    terminal_revision: u64,
    render_revision: u64,
) !void {
    return switch (frame_format) {
        .v2 => writeFrameV2(frame, snapshot, observation_revision, terminal_revision, render_revision),
        .v3 => writeFrameV3(frame, snapshot, observation_revision, terminal_revision, render_revision),
        .v4 => writeFrameV4(frame, snapshot, observation_revision, terminal_revision, render_revision),
    };
}

fn writeFrameV2(
    frame: terminal.Frame,
    snapshot: *const client.view.Snapshot,
    observation_revision: u64,
    terminal_revision: u64,
    render_revision: u64,
) !void {
    var writer = std.Io.Writer.fixed(&metadata);
    try writer.print(
        "{{\"schema\":\"howl.web-frame/v2\",\"render\":{d},\"observation\":{d},\"terminal\":{d},\"surface\":[{d},{d}],\"cell\":[{d},{d}],\"selection_rows\":[",
        .{ render_revision, observation_revision, terminal_revision, surface.width, surface.height, cell_size.width, cell_size.height },
    );
    const begin = client.view.begin(snapshot);
    for (0..begin.terminal.rows) |row| {
        if (row != 0) try writer.writeByte(',');
        const shape = client.selection.rowShape(snapshot, @intCast(row)) orelse
            return error.InvalidSnapshot;
        const encoded_shape = shape.content_end_exclusive |
            (if (shape.wrapped) @as(u16, 1) << 15 else 0);
        try writer.print("{d}", .{encoded_shape});
    }
    try writer.writeAll("],\"uploads\":[");
    for (frame.uploads, 0..) |upload, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print(
            "{{\"q\":[{d},{d}],\"f\":{d},\"z\":[{d},{d}],\"o\":{d},\"n\":{d},\"stride\":{d}}}",
            .{
                @backingInt(upload.resource.resource), @backingInt(upload.resource.generation),
                @backingInt(upload.format),            upload.size.width,
                upload.size.height,                    upload.pixel_offset,
                upload.pixel_count,                    upload.stride,
            },
        );
    }
    try writer.writeAll("],\"removals\":[");
    for (frame.removals, 0..) |removal, index| {
        if (index != 0) try writer.writeByte(',');
        try writeQualified(&writer, removal);
    }
    try writer.writeAll("],\"commands\":[");
    for (frame.commands, 0..) |command, index| {
        if (index != 0) try writer.writeByte(',');
        var info: render_native.CommandInfo = undefined;
        render_native.commandInfo(command, &info);
        switch (info.tag) {
            render_native.c.HRC_SOLID => {
                try writer.writeAll("{\"k\":0,\"r\":");
                try writeRect(
                    &writer,
                    info.destination_x,
                    info.destination_y,
                    info.destination_width,
                    info.destination_height,
                );
                try writer.writeAll(",\"color\":");
                try writeColor(&writer, info.color_rgba);
                try writer.writeByte('}');
            },
            render_native.c.HRC_ALPHA_MASK, render_native.c.HRC_RGBA => {
                try writer.print("{{\"k\":{d},\"d\":", .{info.tag});
                try writeRect(
                    &writer,
                    info.destination_x,
                    info.destination_y,
                    info.destination_width,
                    info.destination_height,
                );
                try writer.writeAll(",\"c\":");
                try writeRect(&writer, info.clip_x, info.clip_y, info.clip_width, info.clip_height);
                try writer.print(",\"q\":[{d},{d}],\"f\":{d},\"z\":[{d},{d}],\"s\":", .{
                    info.resource, info.generation, info.format, info.resource_width, info.resource_height,
                });
                try writeRect(&writer, info.source_x, info.source_y, info.source_width, info.source_height);
                if (info.tag == render_native.c.HRC_ALPHA_MASK) {
                    try writer.writeAll(",\"color\":");
                    try writeColor(&writer, info.color_rgba);
                    try writer.print(",\"cc\":{s}", .{if (info.cursor_component != 0) "true" else "false"});
                }
                try writer.writeByte('}');
            },
            else => return error.InvalidSnapshot,
        }
    }
    try writer.print("] ,\"pixels\":{d},\"residency\":{d}}}", .{ frame.pixels.len, accepted_residency_count });
    metadata_used = writer.end;
}

fn writeFrameV3(
    frame: terminal.Frame,
    snapshot: *const client.view.Snapshot,
    observation_revision: u64,
    terminal_revision: u64,
    render_revision: u64,
) !void {
    // Web frame v3 keeps the readable JSON envelope but makes the high-cardinality
    // command lane positional so dense text does not repeat object keys thousands
    // of times per frame:
    // solid [0,x,y,w,h,r,g,b,a]
    // alpha [1,dx,dy,dw,dh,cx,cy,cw,ch,q,generation,format,rw,rh,sx,sy,sw,sh,r,g,b,a,cursor]
    // rgba  [2,dx,dy,dw,dh,cx,cy,cw,ch,q,generation,format,rw,rh,sx,sy,sw,sh]
    var writer = std.Io.Writer.fixed(&metadata);
    try writer.print(
        "{{\"schema\":\"howl.web-frame/v3\",\"render\":{d},\"observation\":{d},\"terminal\":{d},\"surface\":[{d},{d}],\"cell\":[{d},{d}],\"selection_rows\":[",
        .{ render_revision, observation_revision, terminal_revision, surface.width, surface.height, cell_size.width, cell_size.height },
    );
    const begin = client.view.begin(snapshot);
    for (0..begin.terminal.rows) |row| {
        if (row != 0) try writer.writeByte(',');
        const shape = client.selection.rowShape(snapshot, @intCast(row)) orelse
            return error.InvalidSnapshot;
        const encoded_shape = shape.content_end_exclusive |
            (if (shape.wrapped) @as(u16, 1) << 15 else 0);
        try writer.print("{d}", .{encoded_shape});
    }
    try writer.writeAll("],\"uploads\":[");
    for (frame.uploads, 0..) |upload, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print(
            "{{\"q\":[{d},{d}],\"f\":{d},\"z\":[{d},{d}],\"o\":{d},\"n\":{d},\"stride\":{d}}}",
            .{
                @backingInt(upload.resource.resource), @backingInt(upload.resource.generation),
                @backingInt(upload.format),            upload.size.width,
                upload.size.height,                    upload.pixel_offset,
                upload.pixel_count,                    upload.stride,
            },
        );
    }
    try writer.writeAll("],\"removals\":[");
    for (frame.removals, 0..) |removal, index| {
        if (index != 0) try writer.writeByte(',');
        try writeQualified(&writer, removal);
    }
    try writer.writeAll("],\"commands\":[");
    for (frame.commands, 0..) |command, index| {
        if (index != 0) try writer.writeByte(',');
        var info: render_native.CommandInfo = undefined;
        render_native.commandInfo(command, &info);
        switch (info.tag) {
            render_native.c.HRC_SOLID => {
                try writer.writeAll("[0,");
                try writeRectFields(
                    &writer,
                    info.destination_x,
                    info.destination_y,
                    info.destination_width,
                    info.destination_height,
                );
                try writer.writeByte(',');
                try writeColorFields(&writer, info.color_rgba);
                try writer.writeByte(']');
            },
            render_native.c.HRC_ALPHA_MASK, render_native.c.HRC_RGBA => {
                try writer.print("[{d},", .{info.tag});
                try writeRectFields(
                    &writer,
                    info.destination_x,
                    info.destination_y,
                    info.destination_width,
                    info.destination_height,
                );
                try writer.writeByte(',');
                try writeRectFields(&writer, info.clip_x, info.clip_y, info.clip_width, info.clip_height);
                try writer.print(",{d},{d},{d},{d},{d},", .{
                    info.resource, info.generation, info.format, info.resource_width, info.resource_height,
                });
                try writeRectFields(&writer, info.source_x, info.source_y, info.source_width, info.source_height);
                if (info.tag == render_native.c.HRC_ALPHA_MASK) {
                    try writer.writeByte(',');
                    try writeColorFields(&writer, info.color_rgba);
                    try writer.print(",{d}", .{info.cursor_component});
                }
                try writer.writeByte(']');
            },
            else => return error.InvalidSnapshot,
        }
    }
    try writer.print("] ,\"pixels\":{d},\"residency\":{d}}}", .{ frame.pixels.len, accepted_residency_count });
    metadata_used = writer.end;
}

fn writeFrameV4(
    frame: terminal.Frame,
    snapshot: *const client.view.Snapshot,
    observation_revision: u64,
    terminal_revision: u64,
    render_revision: u64,
) !void {
    try writeCommandWire(frame.commands);
    var writer = std.Io.Writer.fixed(metadata[command_wire_bytes..]);
    try writer.print(
        "{{\"schema\":\"howl.web-frame/v4\",\"render\":{d},\"observation\":{d},\"terminal\":{d},\"surface\":[{d},{d}],\"cell\":[{d},{d}],\"selection_rows\":[",
        .{ render_revision, observation_revision, terminal_revision, surface.width, surface.height, cell_size.width, cell_size.height },
    );
    const begin = client.view.begin(snapshot);
    for (0..begin.terminal.rows) |row| {
        if (row != 0) try writer.writeByte(',');
        const shape = client.selection.rowShape(snapshot, @intCast(row)) orelse
            return error.InvalidSnapshot;
        const encoded_shape = shape.content_end_exclusive |
            (if (shape.wrapped) @as(u16, 1) << 15 else 0);
        try writer.print("{d}", .{encoded_shape});
    }
    try writer.writeAll("],\"uploads\":[");
    for (frame.uploads, 0..) |upload, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print(
            "{{\"q\":[\"{d}\",\"{d}\"],\"f\":{d},\"z\":[{d},{d}],\"o\":{d},\"n\":{d},\"stride\":{d}}}",
            .{
                @backingInt(upload.resource.resource), @backingInt(upload.resource.generation),
                @backingInt(upload.format),            upload.size.width,
                upload.size.height,                    upload.pixel_offset,
                upload.pixel_count,                    upload.stride,
            },
        );
    }
    try writer.writeAll("],\"removals\":[");
    for (frame.removals, 0..) |removal, index| {
        if (index != 0) try writer.writeByte(',');
        try writeQualifiedStrings(&writer, removal);
    }
    try writer.print(
        "],\"command_count\":{d},\"command_stride\":{d},\"pixels\":{d},\"residency\":{d}}}",
        .{ command_wire_count, command_record_bytes, frame.pixels.len, accepted_residency_count },
    );
    metadata_used = writer.end;
}

// Render supplies semantic facts; this host retains the private Web v4 layout.
// Its 64-byte record has different offsets from the 64-byte native C record.
fn writeCommandWire(commands: []const terminal.Command) !void {
    if (commands.len > command_capacity) return error.InvalidSnapshot;
    for (commands, 0..) |command, index| {
        var info: render_native.CommandInfo = undefined;
        render_native.commandInfo(command, &info);
        const record = metadata[index * command_record_bytes ..][0..command_record_bytes];
        @memset(record, 0);
        record[0] = info.tag;
        writeWireRect(record, 4, info.destination_x, info.destination_y, info.destination_width, info.destination_height);
        std.mem.writeInt(u32, record[60..64], info.color_rgba, .little);
        switch (info.tag) {
            render_native.c.HRC_SOLID => {}, // Unused clip/resource/source bytes remain zero.
            render_native.c.HRC_ALPHA_MASK, render_native.c.HRC_RGBA => {
                record[1] = info.format;
                record[2] = info.cursor_component;
                writeWireRect(record, 16, info.clip_x, info.clip_y, info.clip_width, info.clip_height);
                std.mem.writeInt(u64, record[32..40], info.resource, .little);
                std.mem.writeInt(u64, record[40..48], info.generation, .little);
                std.mem.writeInt(u16, record[48..50], info.resource_width, .little);
                std.mem.writeInt(u16, record[50..52], info.resource_height, .little);
                std.mem.writeInt(u16, record[52..54], info.source_x, .little);
                std.mem.writeInt(u16, record[54..56], info.source_y, .little);
                std.mem.writeInt(u16, record[56..58], info.source_width, .little);
                std.mem.writeInt(u16, record[58..60], info.source_height, .little);
            },
            else => return error.InvalidSnapshot,
        }
    }
    command_wire_count = commands.len;
}

fn writeWireRect(record: []u8, offset: usize, x: i32, y: i32, width: u16, height: u16) void {
    std.mem.writeInt(i32, record[offset..][0..4], x, .little);
    std.mem.writeInt(i32, record[offset + 4 ..][0..4], y, .little);
    std.mem.writeInt(u16, record[offset + 8 ..][0..2], width, .little);
    std.mem.writeInt(u16, record[offset + 10 ..][0..2], height, .little);
}

fn writeQualified(writer: *std.Io.Writer, value: terminal.ResourceRef) !void {
    try writer.print("[{d},{d}]", .{
        @backingInt(value.resource), @backingInt(value.generation),
    });
}

fn writeQualifiedStrings(writer: *std.Io.Writer, value: terminal.ResourceRef) !void {
    try writer.print("[\"{d}\",\"{d}\"]", .{
        @backingInt(value.resource), @backingInt(value.generation),
    });
}

// JSON formatting uses only the already-projected native fields. Resource,
// source-rectangle and drawing semantics stay in Render's commandInfo.
fn writeRect(writer: *std.Io.Writer, x: i32, y: i32, width: u16, height: u16) !void {
    try writer.print("[{d},{d},{d},{d}]", .{ x, y, width, height });
}

fn writeColor(writer: *std.Io.Writer, rgba: u32) !void {
    try writer.writeByte('[');
    try writeColorFields(writer, rgba);
    try writer.writeByte(']');
}

fn writeRectFields(writer: *std.Io.Writer, x: i32, y: i32, width: u16, height: u16) !void {
    try writer.print("{d},{d},{d},{d}", .{ x, y, width, height });
}

fn writeColorFields(writer: *std.Io.Writer, rgba: u32) !void {
    try writer.print("{d},{d},{d},{d}", .{
        @as(u8, @truncate(rgba)),
        @as(u8, @truncate(rgba >> 8)),
        @as(u8, @truncate(rgba >> 16)),
        @as(u8, @truncate(rgba >> 24)),
    });
}
