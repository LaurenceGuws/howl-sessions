//! Exercises client.view -> howl-text -> the shared terminal renderer in Wasm.
const std = @import("std");
const client = @import("server_client").terminal;
const terminal = @import("server_client_render");
const render = terminal;
const text = render.text;

/// Traps unexpected Zig failures in the Wasm renderer proof.
pub const panic = std.debug.FullPanic(trapPanic);
fn trapPanic(_: []const u8, _: ?usize) noreturn {
    @trap();
}

var font_bytes: [8 * 1024 * 1024]u8 = undefined;
var heap: [16 * 1024 * 1024]u8 = undefined;
var report: [16384]u8 = undefined;
var report_used: usize = 0;
var frame_pixels: [65536]u8 = undefined;
var frame_pixel_used: usize = 0;
var failure: []const u8 = "";

export fn font_ptr() usize {
    return @intFromPtr(&font_bytes);
}
export fn font_capacity() usize {
    return font_bytes.len;
}
export fn report_ptr() usize {
    return @intFromPtr(&report);
}
export fn report_len() usize {
    return report_used;
}
export fn pixels_ptr() usize {
    return @intFromPtr(&frame_pixels);
}
export fn pixels_len() usize {
    return frame_pixel_used;
}
export fn error_ptr() usize {
    return @intFromPtr(failure.ptr);
}
export fn error_len() usize {
    return failure.len;
}

fn presentation() client.rich.Presentation {
    return .{
        .cursor_age_ns = null,
        .presence_bits = 0,
        .flags = 0,
        .reverse_screen = false,
        .palette = @splat(.{ .r = 0, .g = 0, .b = 0, .a = 0xff }),
        .foreground = .{ .r = 0xe8, .g = 0xee, .b = 0xf2, .a = 0xff },
        .background = .{ .r = 12, .g = 18, .b = 24, .a = 0xff },
        .cursor = null,
        .cursor_text = null,
        .selection_background = null,
        .selection_foreground = null,
    };
}

fn cell(scalars: []const u32) client.rich.Cell {
    return .{
        .scalars = scalars,
        .width = 1,
        .height = 1,
        .x = 0,
        .y = 0,
        .subscale_n = 0,
        .subscale_d = 0,
        .vertical_align = 0,
        .horizontal_align = 0,
        .semantic_width = false,
        .font = 0,
        .baseline = 0,
        .underline_style = 0,
        .protection = 0,
        .style_bits = 0,
        .foreground = .{ .kind = .default, .value = 0 },
        .background = .{ .kind = .default, .value = 0 },
        .underline_color = .{ .kind = .default, .value = 0 },
        .link_id = 0,
    };
}

export fn run(length: usize) u32 {
    failure = "";
    report_used = 0;
    frame_pixel_used = 0;
    if (length == 0 or length > font_bytes.len) {
        failure = "InvalidFontLength";
        return 0;
    }
    execute(font_bytes[0..length]) catch |err| {
        failure = @errorName(err);
        return 0;
    };
    return 1;
}

fn execute(font_input: []u8) !void {
    var memory = std.heap.FixedBufferAllocator.init(&heap);
    const allocator = memory.allocator();
    const fonts = try text.FontSet.initMemory(allocator, .{
        .primary = font_input,
        .size = .{ .pixels = 18 },
    });
    defer fonts.deinit();
    @memset(font_input, 0xa5);
    const metrics = fonts.metrics();

    var a = [_]u32{'f'};
    var b = [_]u32{'f'};
    var c = [_]u32{'i'};
    var d = [_]u32{ 'e', 0x0301 };
    var e = [_]u32{0x03bb};
    var box = [_]u32{0x2500};
    const empty: []const u32 = &.{};
    var cells = [_]client.rich.Cell{
        cell(&a),   cell(&b),    cell(&c), cell(empty),
        cell(&d),   cell(empty), cell(&e), cell(empty),
        cell(&box),
    };
    var rows = [_]client.rich.Row{.{ .wrapped = false, .line_geometry = 0, .cells = &cells }};
    var source = client.rich.Snapshot{
        .allocator = allocator,
        .begin = .{
            .revision = 17,
            .terminal = .{
                .revision = 11,
                .history_offset = 0,
                .history_count = 0,
                .history_row_base = 0,
                .rows = 1,
                .columns = cells.len,
                .cursor_row = 0,
                .cursor_column = 0,
                .cursor_shape = 0,
                .cursor_visible = false,
                .cursor_blink = false,
                .alternate_screen = false,
            },
            .stream_closed = false,
            .child_exited = false,
            .leader_present = false,
            .you_are_leader = false,
        },
        .presentation = presentation(),
        .rows = &rows,
        .hyperlinks = &.{},
    };
    const view = try client.view.project(allocator, &source);
    defer client.view.deinit(view);

    const terminal_renderer = try terminal.initPrivate(allocator, terminal.FontFaces.single(fonts), .{
        .cell_size = .{ .width = metrics.advance_width, .height = metrics.line_height },
        .box_drawing = .{
            .dpi_x = .{ .numerator = 96, .denominator = 1 },
            .dpi_y = .{ .numerator = 96, .denominator = 1 },
        },
        .shape_cache = .{ .entry_capacity = 32, .scalar_capacity = 64, .glyph_capacity = 64, .max_sequence_scalars = 16 },
        .atlas = .{ .width = 256, .height = 256, .entry_capacity = 64 },
        .shaped_capacity = 64,
        .raster_bytes = 65536,
        .command_capacity = 128,
    });
    defer terminal.deinit(terminal_renderer);
    try terminal.update(terminal_renderer, view);
    const surface = terminal.Size{
        .width = @intCast(@as(u32, metrics.advance_width) * cells.len),
        .height = metrics.line_height,
    };
    var uploads: [2]terminal.FrameResourceUpload = undefined;
    var removals: [2]terminal.ResourceRef = undefined;
    var commands: [128]terminal.Command = undefined;
    const frame = try terminal.frame(terminal_renderer, &.{}, .{
        .uploads = &uploads,
        .removals = &removals,
        .commands = &commands,
        .pixels = &frame_pixels,
    });
    frame_pixel_used = frame.pixels.len;
    var alpha_commands: usize = 0;
    var solid_commands: usize = 0;
    for (frame.commands) |command| switch (command) {
        .alpha_mask => alpha_commands += 1,
        .solid => solid_commands += 1,
        .rgba => {},
    };
    var writer = std.Io.Writer.fixed(&report);
    try std.json.Stringify.value(.{
        .schema = "howl.web-render-proof/v1",
        .surface = surface,
        .metrics = metrics,
        .producer_revision = terminal.usage(terminal_renderer).revision,
        .shape_entries = terminal.usage(terminal_renderer).shape.entries,
        .atlas_entries = terminal.usage(terminal_renderer).atlas_entries,
        .uploads = frame.uploads.len,
        .commands = frame.commands.len,
        .alpha_commands = alpha_commands,
        .solid_commands = solid_commands,
        .pixel_bytes = frame.pixels.len,
        .caller_font_overwritten = std.mem.allEqual(u8, font_input, 0xa5),
    }, .{}, &writer);
    report_used = writer.end;
}
