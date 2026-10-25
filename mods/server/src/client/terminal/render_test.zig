//! Proves one bounded terminal renderer through the final backend-facing frame.

const std = @import("std");
const client = @import("terminal_client");
const fonts = @import("test_fonts");
const terminal = @import("server_client_render");
const text = terminal.text;
const generated = text.generated;

fn presentation() client.rich.Presentation {
    return .{
        .cursor_age_ns = null,
        .presence_bits = 0,
        .flags = 0,
        .reverse_screen = false,
        .palette = @splat(.{ .r = 0, .g = 0, .b = 0, .a = 0xff }),
        .foreground = .{ .r = 0xee, .g = 0xee, .b = 0xee, .a = 0xff },
        .background = .{ .r = 1, .g = 2, .b = 3, .a = 0xff },
        .cursor = null,
        .cursor_text = null,
        .selection_background = null,
        .selection_foreground = null,
    };
}

fn cell(scalars: []u32, width: u8, x: u8) client.rich.Cell {
    return .{
        .scalars = scalars,
        .width = width,
        .height = 1,
        .x = x,
        .y = 0,
        .subscale_n = 0,
        .subscale_d = 0,
        .vertical_align = 0,
        .horizontal_align = 0,
        .semantic_width = width > 1,
        .font = 0,
        .baseline = 0,
        .underline_style = 0,
        .protection = 0,
        .style_bits = 1,
        .foreground = .{ .kind = .rgb, .value = 0xabcdef },
        .background = .{ .kind = .default, .value = 0 },
        .underline_color = .{ .kind = .default, .value = 0 },
        .link_id = 0,
    };
}

fn sourceSnapshot(rows: []client.rich.Row, columns: u16) client.rich.Snapshot {
    return .{
        .allocator = std.testing.allocator,
        .begin = .{
            .revision = 17,
            .terminal = .{
                .revision = 11,
                .history_offset = 0,
                .history_count = 0,
                .history_row_base = 0,
                .rows = @intCast(rows.len),
                .columns = columns,
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
        .rows = rows,
        .hyperlinks = &.{},
    };
}

fn rendererConfig(command_capacity: usize) terminal.Config {
    return .{
        .cell_size = .{ .width = 10, .height = 20 },
        .box_drawing = .{
            .dpi_x = .{ .numerator = 96, .denominator = 1 },
            .dpi_y = .{ .numerator = 96, .denominator = 1 },
        },
        .shape_cache = .{
            .entry_capacity = 16,
            .scalar_capacity = 32,
            .glyph_capacity = 32,
            .max_sequence_scalars = 8,
        },
        .atlas = .{ .width = 64, .height = 64, .entry_capacity = 16 },
        .shaped_capacity = 16,
        .raster_bytes = 4096,
        .command_capacity = command_capacity,
    };
}

fn storeConfig(config: terminal.Config) terminal.StoreConfig {
    return .{
        .shape_cache = config.shape_cache,
        .shaped_capacity = config.shaped_capacity,
        .raster_bytes = config.raster_bytes,
    };
}

fn terminalFont() !*text.FontSet {
    return text.FontSet.init(std.testing.allocator, .{
        .primary = fonts.primary_font,
        .size = .{ .pixels = 16 },
    });
}

const Presented = struct {
    frame: terminal.Frame,
    external: []const terminal.FrameExternalResource,
};

const Harness = struct {
    allocator: std.mem.Allocator,
    renderer: *terminal.Renderer,
    uploads: []terminal.FrameResourceUpload,
    removals: []terminal.ResourceRef,
    commands: []terminal.Command,
    pixels: []u8,
    residencies: [terminal.maximum_frame_resources]terminal.Residency = undefined,
    residency_count: usize = 0,
    missing: [terminal.maximum_external_images]terminal.FrameExternalResource = undefined,

    fn init(
        allocator: std.mem.Allocator,
        font: *text.FontSet,
        config: terminal.Config,
    ) !Harness {
        return initFaces(allocator, terminal.FontFaces.single(font), config);
    }

    fn initFaces(
        allocator: std.mem.Allocator,
        font_faces: terminal.FontFaces,
        config: terminal.Config,
    ) !Harness {
        const owner = try terminal.initPrivate(allocator, font_faces, config);
        errdefer terminal.deinit(owner);
        const uploads = try allocator.alloc(terminal.FrameResourceUpload, terminal.maximum_frame_resources);
        errdefer allocator.free(uploads);
        const removals = try allocator.alloc(terminal.ResourceRef, terminal.maximum_frame_resources);
        errdefer allocator.free(removals);
        const commands = try allocator.alloc(terminal.Command, config.command_capacity + 128);
        errdefer allocator.free(commands);
        const pixel_count = std.math.mul(usize, config.atlas.width, config.atlas.height) catch
            return error.OutOfMemory;
        const pixels = try allocator.alloc(u8, pixel_count);
        return .{
            .allocator = allocator,
            .renderer = owner,
            .uploads = uploads,
            .removals = removals,
            .commands = commands,
            .pixels = pixels,
        };
    }

    fn deinit(self: *Harness) void {
        terminal.deinit(self.renderer);
        self.allocator.free(self.pixels);
        self.allocator.free(self.commands);
        self.allocator.free(self.removals);
        self.allocator.free(self.uploads);
        self.* = undefined;
    }

    fn present(self: *Harness, view: *const client.view.Snapshot) !Presented {
        return self.presentWithBindings(view, &.{});
    }

    fn presentWithBindings(
        self: *Harness,
        view: *const client.view.Snapshot,
        bindings: []const terminal.ExternalImageBinding,
    ) !Presented {
        try terminal.updateWithImageBindings(self.renderer, view, bindings);
        return self.finishPresent();
    }

    fn presentRich(self: *Harness, view: *const client.rich.View) !Presented {
        return self.presentRichWithBindings(view, &.{});
    }

    fn presentRichWithBindings(
        self: *Harness,
        view: *const client.rich.View,
        bindings: []const terminal.ExternalImageBinding,
    ) !Presented {
        try terminal.updateRichWithImageBindings(self.renderer, view, bindings);
        return self.finishPresent();
    }

    fn finishPresent(self: *Harness) !Presented {
        const external = try terminal.missingExternalResources(
            self.renderer,
            self.residencies[0..self.residency_count],
            &self.missing,
        );
        for (external) |value| try self.upsert(.{
            .resource = value.resource,
            .format = value.format,
            .size = value.size,
        });
        const frame = try terminal.frame(
            self.renderer,
            self.residencies[0..self.residency_count],
            .{
                .uploads = self.uploads,
                .removals = self.removals,
                .commands = self.commands,
                .pixels = self.pixels,
            },
        );
        try self.acceptFrame(frame);
        return .{ .frame = frame, .external = external };
    }

    fn upsert(self: *Harness, value: terminal.Residency) !void {
        for (self.residencies[0..self.residency_count]) |*existing| {
            if (existing.resource.resource == value.resource.resource) {
                existing.* = value;
                return;
            }
        }
        if (self.residency_count == self.residencies.len) return error.ResidencyLimit;
        self.residencies[self.residency_count] = value;
        self.residency_count += 1;
    }

    fn acceptFrame(self: *Harness, value: terminal.Frame) !void {
        for (value.removals) |removal| {
            var index: usize = 0;
            while (index < self.residency_count) : (index += 1) {
                if (self.residencies[index].resource.resource != removal.resource) continue;
                self.residency_count -= 1;
                self.residencies[index] = self.residencies[self.residency_count];
                break;
            }
        }
        for (value.uploads) |upload| try self.upsert(.{
            .resource = upload.resource,
            .format = upload.format,
            .size = upload.size,
        });
    }
};

fn firstAlpha(commands: []const terminal.Command) ?@FieldType(terminal.Command, "alpha_mask") {
    for (commands) |command| switch (command) {
        .alpha_mask => |value| return value,
        else => {},
    };
    return null;
}

fn firstRgba(commands: []const terminal.Command) ?@FieldType(terminal.Command, "rgba") {
    for (commands) |command| switch (command) {
        .rgba => |value| return value,
        else => {},
    };
    return null;
}

fn constructTerminalrenderer(allocator: std.mem.Allocator, font: *text.FontSet) !void {
    const owner = try terminal.initPrivate(allocator, terminal.FontFaces.single(font), rendererConfig(64));
    terminal.deinit(owner);
}

test "two terminal renderers borrow one externally serialized process store" {
    const font = try terminalFont();
    defer font.deinit();
    const config = rendererConfig(64);
    const store = try terminal.initStore(
        std.testing.allocator,
        terminal.FontFaces.single(font),
        storeConfig(config),
    );
    defer terminal.deinitStore(store);
    try std.testing.expectEqualDeep(font.metrics(), terminal.storeMetrics(store));

    const first = try terminal.initWithStore(std.testing.allocator, store, config);
    defer terminal.deinit(first);
    const second = try terminal.initWithStore(std.testing.allocator, store, config);
    defer terminal.deinit(second);

    var scalar = [_]u32{'A'};
    var cells = [_]client.rich.Cell{cell(&scalar, 1, 0)};
    var rows = [_]client.rich.Row{.{ .wrapped = false, .line_geometry = 0, .cells = &cells }};
    const source = sourceSnapshot(&rows, 1);
    const view = try client.view.project(std.testing.allocator, &source);
    defer client.view.deinit(view);

    try terminal.update(first, view);
    const after_first = terminal.storeUsage(store).shape;
    try std.testing.expect(after_first.entries != 0);
    try terminal.update(second, view);
    const after_second = terminal.storeUsage(store).shape;
    try std.testing.expectEqualDeep(after_first, after_second);

    const neighbour = terminal.usage(second);
    try terminal.resetCaches(first);
    try std.testing.expectEqualDeep(after_second, terminal.storeUsage(store).shape);
    try std.testing.expectEqualDeep(neighbour, terminal.usage(second));

    // Resetting the shared shape cache is explicit process-lane behavior; the
    // terminal-local atlases and completed command sets remain independently owned.
    terminal.resetStore(store);
    try std.testing.expectEqual(@as(usize, 0), terminal.storeUsage(store).shape.entries);
}

test "terminal renderer owns final atlas residency and recovers after backend loss" {
    var scalar = [_]u32{'A'};
    var cells = [_]client.rich.Cell{cell(&scalar, 1, 0)};
    var rows = [_]client.rich.Row{.{ .wrapped = false, .line_geometry = 0, .cells = &cells }};
    const source = sourceSnapshot(&rows, 1);
    const view = try client.view.project(std.testing.allocator, &source);
    defer client.view.deinit(view);
    const font = try terminalFont();
    defer font.deinit();
    var host = try Harness.init(std.testing.allocator, font, rendererConfig(64));
    defer host.deinit();

    const first = try host.present(view);
    try std.testing.expectEqual(@as(usize, 1), first.frame.uploads.len);
    try std.testing.expect(firstAlpha(first.frame.commands) != null);
    try std.testing.expectEqual(@as(u64, 1), first.frame.revision);
    const first_resource = first.frame.uploads[0].resource;

    const second = try host.present(view);
    try std.testing.expectEqual(@as(usize, 0), second.frame.uploads.len);
    try std.testing.expectEqual(@as(u64, 2), second.frame.revision);
    try std.testing.expectEqual(first_resource, firstAlpha(second.frame.commands).?.resource.resource);

    host.residency_count = 0;
    const replay = try terminal.frame(host.renderer, &.{}, .{
        .uploads = host.uploads,
        .removals = host.removals,
        .commands = host.commands,
        .pixels = host.pixels,
    });
    try std.testing.expectEqual(@as(usize, 1), replay.uploads.len);
    try std.testing.expectEqual(first_resource, replay.uploads[0].resource);

    try terminal.resetCaches(host.renderer);
    try std.testing.expectError(error.InvalidView, host.finishPresent());
    try std.testing.expectError(error.InvalidView, terminal.frame(host.renderer, &.{}, .{
        .uploads = host.uploads,
        .removals = host.removals,
        .commands = host.commands,
        .pixels = host.pixels,
    }));
    host.residency_count = 1;
    host.residencies[0] = .{ .resource = first_resource, .format = .alpha8, .size = replay.uploads[0].size };
    const regenerated = try host.present(view);
    try std.testing.expectEqual(@as(usize, 1), regenerated.frame.uploads.len);
    try std.testing.expectEqual(@as(usize, 0), regenerated.frame.removals.len);
    try std.testing.expectEqual(@backingInt(first_resource.resource), @backingInt(regenerated.frame.uploads[0].resource.resource));
    try std.testing.expect(@backingInt(regenerated.frame.uploads[0].resource.generation) > @backingInt(first_resource.generation));
}

test "terminal atlas pressure rolls only its atlas and preserves shaping knowledge" {
    var scalar_a = [_]u32{'A'};
    var scalar_b = [_]u32{'B'};
    var scalar_c = [_]u32{'C'};
    var cells_a = [_]client.rich.Cell{cell(&scalar_a, 1, 0)};
    var cells_b = [_]client.rich.Cell{cell(&scalar_b, 1, 0)};
    var cells_c = [_]client.rich.Cell{cell(&scalar_c, 1, 0)};
    var rows_a = [_]client.rich.Row{.{ .wrapped = false, .line_geometry = 0, .cells = &cells_a }};
    var rows_b = [_]client.rich.Row{.{ .wrapped = false, .line_geometry = 0, .cells = &cells_b }};
    var rows_c = [_]client.rich.Row{.{ .wrapped = false, .line_geometry = 0, .cells = &cells_c }};
    const source_a = sourceSnapshot(&rows_a, 1);
    const source_b = sourceSnapshot(&rows_b, 1);
    const source_c = sourceSnapshot(&rows_c, 1);
    const view_a = try client.view.project(std.testing.allocator, &source_a);
    defer client.view.deinit(view_a);
    const view_b = try client.view.project(std.testing.allocator, &source_b);
    defer client.view.deinit(view_b);
    const view_c = try client.view.project(std.testing.allocator, &source_c);
    defer client.view.deinit(view_c);

    const font = try terminalFont();
    defer font.deinit();
    var config = rendererConfig(64);
    config.atlas.entry_capacity = 2;
    var host = try Harness.init(std.testing.allocator, font, config);
    defer host.deinit();

    const first = try host.present(view_a);
    try std.testing.expectEqual(@as(usize, 1), terminal.usage(host.renderer).atlas_entries);
    const first_atlas = first.frame.uploads[0].resource;

    const second = try host.present(view_b);
    try std.testing.expectEqual(@as(usize, 2), terminal.usage(host.renderer).atlas_entries);
    const second_atlas = second.frame.uploads[0].resource;
    try std.testing.expectEqual(first_atlas.resource, second_atlas.resource);
    try std.testing.expect(@backingInt(second_atlas.generation) > @backingInt(first_atlas.generation));

    const third = try host.present(view_c);
    const rolled = terminal.usage(host.renderer);
    try std.testing.expectEqual(@as(usize, 1), rolled.atlas_entries);
    try std.testing.expectEqual(@as(usize, 3), rolled.shape.entries);
    try std.testing.expectEqual(@as(u64, 3), third.frame.revision);
    try std.testing.expectEqual(@as(usize, 1), third.frame.uploads.len);
    const third_atlas = third.frame.uploads[0].resource;
    try std.testing.expectEqual(first_atlas.resource, third_atlas.resource);
    try std.testing.expect(@backingInt(third_atlas.generation) > @backingInt(second_atlas.generation));
}

test "terminal renderer reports cache pressure when one frame cannot fit after rollover" {
    var scalar_a = [_]u32{'A'};
    var scalar_b = [_]u32{'B'};
    var cells = [_]client.rich.Cell{ cell(&scalar_a, 1, 0), cell(&scalar_b, 1, 0) };
    var rows = [_]client.rich.Row{.{ .wrapped = false, .line_geometry = 0, .cells = &cells }};
    const source = sourceSnapshot(&rows, 2);
    const view = try client.view.project(std.testing.allocator, &source);
    defer client.view.deinit(view);

    const font = try terminalFont();
    defer font.deinit();
    var config = rendererConfig(64);
    config.atlas.entry_capacity = 1;
    var host = try Harness.init(std.testing.allocator, font, config);
    defer host.deinit();

    try std.testing.expectError(error.CacheFull, terminal.update(host.renderer, view));
    try std.testing.expectEqual(@as(usize, 1), terminal.usage(host.renderer).atlas_entries);
    try std.testing.expectError(error.InvalidView, host.finishPresent());
}

test "terminal renderer generated box raster remains exact in the final frame" {
    var symbol = [_]u32{0x2500};
    var cells = [_]client.rich.Cell{cell(&symbol, 1, 0)};
    var rows = [_]client.rich.Row{.{ .wrapped = false, .line_geometry = 0, .cells = &cells }};
    const source = sourceSnapshot(&rows, 1);
    const view = try client.view.project(std.testing.allocator, &source);
    defer client.view.deinit(view);
    const font = try terminalFont();
    defer font.deinit();
    const config = rendererConfig(64);
    var host = try Harness.init(std.testing.allocator, font, config);
    defer host.deinit();
    const presented = try host.present(view);
    try std.testing.expectEqual(@as(usize, 1), presented.frame.uploads.len);
    const upload = presented.frame.uploads[0];
    var expected: [10 * 20]u8 = undefined;
    try generated.rasterizeBox(&expected, 10, 20, symbol[0], config.box_drawing, .{});
    for (0..20) |row| {
        const at = upload.pixel_offset + row * upload.stride;
        try std.testing.expectEqualSlices(
            u8,
            expected[row * 10 ..][0..10],
            presented.frame.pixels[at..][0..10],
        );
    }
    const usage = terminal.usage(host.renderer);
    try std.testing.expectEqual(@as(usize, 1), usage.atlas_entries);
    try std.testing.expectEqual(@as(usize, 0), usage.shape.entries);
}

test "terminal renderer final commands preserve DEC double width and height" {
    var block = [_]u32{0x2588};
    var empty = [_]u32{};
    var row0_cells = [_]client.rich.Cell{ cell(&block, 1, 0), cell(&empty, 1, 0) };
    var row1_cells = row0_cells;
    var row2_cells = row0_cells;
    var row3_cells = row0_cells;
    var rows = [_]client.rich.Row{
        .{ .wrapped = false, .line_geometry = 0, .cells = &row0_cells },
        .{ .wrapped = false, .line_geometry = 1, .cells = &row1_cells },
        .{ .wrapped = false, .line_geometry = 2, .cells = &row2_cells },
        .{ .wrapped = false, .line_geometry = 3, .cells = &row3_cells },
    };
    const source = sourceSnapshot(&rows, 2);
    const view = try client.view.project(std.testing.allocator, &source);
    defer client.view.deinit(view);
    const font = try terminalFont();
    defer font.deinit();
    var host = try Harness.init(std.testing.allocator, font, rendererConfig(32));
    defer host.deinit();
    const frame = (try host.present(view)).frame;
    var destinations: [4]terminal.Rect = undefined;
    var clips: [4]terminal.Rect = undefined;
    var sources: [4]terminal.SourceRect = undefined;
    var count: usize = 0;
    for (frame.commands) |command| switch (command) {
        .alpha_mask => |value| {
            if (count == destinations.len) return error.TooManyAlphaCommands;
            destinations[count] = value.destination;
            clips[count] = value.clip;
            sources[count] = value.resource.source.?;
            count += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(destinations.len, count);
    try std.testing.expectEqualDeep([4]terminal.Rect{
        .{ .x = 0, .y = 0, .width = 10, .height = 20 },
        .{ .x = 0, .y = 20, .width = 20, .height = 20 },
        .{ .x = 0, .y = 40, .width = 20, .height = 40 },
        .{ .x = 0, .y = 40, .width = 20, .height = 40 },
    }, destinations);
    try std.testing.expectEqualDeep([4]terminal.Rect{
        .{ .x = 0, .y = 0, .width = 10, .height = 20 },
        .{ .x = 0, .y = 20, .width = 20, .height = 20 },
        .{ .x = 0, .y = 40, .width = 20, .height = 20 },
        .{ .x = 0, .y = 60, .width = 20, .height = 20 },
    }, clips);
    for (sources) |source_rect| try std.testing.expectEqualDeep(
        terminal.SourceRect{ .x = 0, .y = 0, .width = 10, .height = 20 },
        source_rect,
    );
}

test "terminal renderer projects OSC 66 fraction and alignment once" {
    var block = [_]u32{0x2588};
    var empty = [_]u32{};
    var lead = cell(&block, 3, 0);
    lead.height = 3;
    lead.semantic_width = false;
    lead.subscale_n = 1;
    lead.subscale_d = 2;
    lead.vertical_align = 1;
    lead.horizontal_align = 2;
    var row0_cells = [_]client.rich.Cell{ lead, lead, lead };
    var row1_cells = row0_cells;
    var row2_cells = row0_cells;
    for (&row0_cells, 0..) |*value, x| {
        value.x = @intCast(x);
        if (x != 0) value.scalars = &empty;
    }
    for (&row1_cells, 0..) |*value, x| {
        value.x = @intCast(x);
        value.y = 1;
        value.scalars = &empty;
    }
    for (&row2_cells, 0..) |*value, x| {
        value.x = @intCast(x);
        value.y = 2;
        value.scalars = &empty;
    }
    var rows = [_]client.rich.Row{
        .{ .wrapped = false, .line_geometry = 0, .cells = &row0_cells },
        .{ .wrapped = false, .line_geometry = 0, .cells = &row1_cells },
        .{ .wrapped = false, .line_geometry = 0, .cells = &row2_cells },
    };
    const source = sourceSnapshot(&rows, 3);
    const view = try client.view.project(std.testing.allocator, &source);
    defer client.view.deinit(view);
    const font = try terminalFont();
    defer font.deinit();
    var host = try Harness.init(std.testing.allocator, font, rendererConfig(32));
    defer host.deinit();
    const frame = (try host.present(view)).frame;
    const alpha = firstAlpha(frame.commands) orelse return error.MissingAlpha;
    try std.testing.expectEqualDeep(terminal.Rect{ .x = 7, .y = 30, .width = 15, .height = 30 }, alpha.destination);
    // The producer allocates 30x60, but final clips intersect destination,
    // allocation and surface. The half-scale, centered/bottom-aligned 15x30
    // destination fits entirely: the backend must not paint its unused margins.
    try std.testing.expectEqualDeep(alpha.destination, alpha.clip);
    try std.testing.expectEqualDeep(terminal.SourceRect{ .x = 0, .y = 0, .width = 15, .height = 30 }, alpha.resource.source.?);
}

test "terminal renderer resolves style colors decorations and invisibility in final commands" {
    var a = [_]u32{'A'};
    var b = [_]u32{'B'};
    var c = [_]u32{'C'};
    var cells = [_]client.rich.Cell{ cell(&a, 1, 0), cell(&b, 1, 0), cell(&c, 1, 0) };
    cells[0].foreground = .{ .kind = .indexed, .value = 1 };
    cells[0].background = .{ .kind = .rgb, .value = 0x040506 };
    cells[0].style_bits = 1 << 1;
    cells[1].style_bits = (1 << 5) | (1 << 7) | (1 << 8);
    cells[1].underline_style = 3;
    cells[1].underline_color = .{ .kind = .rgb, .value = 0x445566 };
    cells[2].style_bits = 1 << 6;
    cells[2].background = .{ .kind = .indexed, .value = 4 };
    var rows = [_]client.rich.Row{.{ .wrapped = false, .line_geometry = 0, .cells = &cells }};
    var source = sourceSnapshot(&rows, 3);
    source.presentation.palette[1] = .{ .r = 205, .g = 49, .b = 49, .a = 255 };
    source.presentation.palette[4] = .{ .r = 36, .g = 114, .b = 200, .a = 255 };
    const view = try client.view.project(std.testing.allocator, &source);
    defer client.view.deinit(view);
    const font = try terminalFont();
    defer font.deinit();
    var host = try Harness.init(std.testing.allocator, font, rendererConfig(64));
    defer host.deinit();
    const frame = (try host.present(view)).frame;

    var alpha_count: usize = 0;
    var saw_dim_red = false;
    var saw_reverse_foreground = false;
    var saw_a_background = false;
    var saw_b_background = false;
    var saw_invisible_background = false;
    var decoration_count: usize = 0;
    for (frame.commands) |command| switch (command) {
        .alpha_mask => |value| {
            alpha_count += 1;
            if (value.destination.x < 10) saw_dim_red = std.meta.eql(value.color, terminal.Color{
                .r = 205,
                .g = 49,
                .b = 49,
                .a = 140,
            }) else if (value.destination.x < 20) saw_reverse_foreground = std.meta.eql(value.color, terminal.Color{
                .r = 1,
                .g = 2,
                .b = 3,
                .a = 255,
            });
        },
        .solid => |value| {
            if (value.rect.x == 0 and value.rect.width == 10 and
                std.meta.eql(value.color, terminal.Color{ .r = 4, .g = 5, .b = 6, .a = 255 }))
                saw_a_background = true;
            if (value.rect.x == 10 and value.rect.width == 10 and
                std.meta.eql(value.color, terminal.Color{ .r = 0xab, .g = 0xcd, .b = 0xef, .a = 255 }))
                saw_b_background = true;
            if (value.rect.x == 20 and value.rect.width == 10 and
                std.meta.eql(value.color, terminal.Color{ .r = 36, .g = 114, .b = 200, .a = 255 }))
                saw_invisible_background = true;
            if (std.meta.eql(value.color, terminal.Color{ .r = 0x44, .g = 0x55, .b = 0x66, .a = 255 }))
                decoration_count += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), alpha_count);
    try std.testing.expect(saw_dim_red and saw_reverse_foreground);
    try std.testing.expect(saw_a_background and saw_b_background and saw_invisible_background);
    try std.testing.expect(decoration_count >= 6);
}

test "terminal renderer missing style variants share regular cache identity" {
    var scalar = [_]u32{'A'};
    var cells = [_]client.rich.Cell{
        cell(&scalar, 1, 0),
        cell(&scalar, 1, 0),
        cell(&scalar, 1, 0),
        cell(&scalar, 1, 0),
    };
    cells[0].style_bits = 0;
    cells[1].style_bits = 1 << 2;
    cells[2].style_bits = 1 << 0;
    cells[3].style_bits = (1 << 0) | (1 << 2);

    var rows = [_]client.rich.Row{.{ .wrapped = false, .line_geometry = 0, .cells = &cells }};
    const source = sourceSnapshot(&rows, cells.len);
    const view = try client.view.project(std.testing.allocator, &source);
    defer client.view.deinit(view);

    const regular = try terminalFont();
    defer regular.deinit();
    var host = try Harness.init(std.testing.allocator, regular, rendererConfig(64));
    defer host.deinit();

    const presented = try host.present(view);
    try std.testing.expect(presented.frame.revision != 0);
    const usage = terminal.usage(host.renderer);
    try std.testing.expectEqual(@as(usize, 1), usage.shape.entries);
    try std.testing.expectEqual(@as(usize, 1), usage.atlas_entries);
}

test "contextual operator shaping ignores non-glyph cell metadata" {
    var equal = [_]u32{'='};
    var greater = [_]u32{'>'};
    var cells = [_]client.rich.Cell{
        cell(&equal, 1, 0),
        cell(&greater, 1, 0),
    };
    cells[1].protection = 1;
    var rows = [_]client.rich.Row{.{
        .wrapped = false,
        .line_geometry = 0,
        .cells = &cells,
    }};
    const source = sourceSnapshot(&rows, 2);
    const view = try client.view.project(std.testing.allocator, &source);
    defer client.view.deinit(view);

    const font = try terminalFont();
    defer font.deinit();
    var host = try Harness.init(std.testing.allocator, font, rendererConfig(32));
    defer host.deinit();

    const presented = try host.present(view);
    try std.testing.expect(presented.frame.revision != 0);
    try std.testing.expectEqual(@as(usize, 0), terminal.usage(host.renderer).shape.entries);
}

test "terminal renderer routes bold italic combinations through independent font owners" {
    var scalar = [_]u32{'A'};
    var cells = [_]client.rich.Cell{
        cell(&scalar, 1, 0),
        cell(&scalar, 1, 0),
        cell(&scalar, 1, 0),
        cell(&scalar, 1, 0),
    };
    cells[0].style_bits = 0;
    cells[1].style_bits = 1 << 2;
    cells[2].style_bits = 1 << 0;
    cells[3].style_bits = (1 << 0) | (1 << 2);

    var rows = [_]client.rich.Row{.{ .wrapped = false, .line_geometry = 0, .cells = &cells }};
    const source = sourceSnapshot(&rows, cells.len);
    const view = try client.view.project(std.testing.allocator, &source);
    defer client.view.deinit(view);

    const regular = try terminalFont();
    defer regular.deinit();
    const italic = try terminalFont();
    defer italic.deinit();
    const bold = try terminalFont();
    defer bold.deinit();
    const bold_italic = try terminalFont();
    defer bold_italic.deinit();

    var host = try Harness.initFaces(std.testing.allocator, .{
        .regular = regular,
        .italic = italic,
        .bold = bold,
        .bold_italic = bold_italic,
    }, rendererConfig(64));
    defer host.deinit();

    const frame = (try host.present(view)).frame;
    var alpha_count: usize = 0;
    for (frame.commands) |command| switch (command) {
        .alpha_mask => alpha_count += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 4), alpha_count);

    const usage = terminal.usage(host.renderer);
    try std.testing.expectEqual(@as(usize, 4), usage.shape.entries);
    try std.testing.expectEqual(@as(usize, 4), usage.atlas_entries);
}

test "terminal renderer curly underline uses one smooth atlas mask without staircase solids" {
    var scalar = [_]u32{'A'};
    var cells = [_]client.rich.Cell{cell(&scalar, 1, 0)};
    cells[0].style_bits = 1 << 7;
    cells[0].underline_style = 2;
    cells[0].underline_color = .{ .kind = .rgb, .value = 0x445566 };

    var rows = [_]client.rich.Row{.{ .wrapped = false, .line_geometry = 0, .cells = &cells }};
    const source = sourceSnapshot(&rows, 1);
    const view = try client.view.project(std.testing.allocator, &source);
    defer client.view.deinit(view);

    const font = try terminalFont();
    defer font.deinit();
    var host = try Harness.init(std.testing.allocator, font, rendererConfig(32));
    defer host.deinit();
    const frame = (try host.present(view)).frame;

    const decoration = terminal.Color{ .r = 0x44, .g = 0x55, .b = 0x66, .a = 255 };
    var curly_masks: usize = 0;
    var old_staircase_solids: usize = 0;
    var curly_source: ?terminal.SourceRect = null;
    for (frame.commands) |command| switch (command) {
        .alpha_mask => |value| {
            if (std.meta.eql(value.color, decoration)) {
                curly_masks += 1;
                const source_rect = value.resource.source orelse return error.MissingAlpha;
                curly_source = source_rect;
                try std.testing.expectEqual(@as(u16, 10), source_rect.width);
            }
        },
        .solid => |value| {
            if (std.meta.eql(value.color, decoration))
                old_staircase_solids += 1;
        },
        else => {},
    };

    try std.testing.expectEqual(@as(usize, 1), curly_masks);
    try std.testing.expectEqual(@as(usize, 0), old_staircase_solids);
    const source_rect = curly_source orelse return error.MissingAlpha;
    try std.testing.expect(source_rect.height > 2);
    try std.testing.expectEqual(@as(usize, 1), frame.uploads.len);
    const upload = frame.uploads[0];
    var saw_fractional_alpha = false;
    for (0..source_rect.height) |row| {
        const start =
            upload.pixel_offset +
            (@as(usize, source_rect.y) + row) * upload.stride +
            source_rect.x;
        for (frame.pixels[start..][0..source_rect.width]) |alpha| {
            if (alpha != 0 and alpha != 255) saw_fractional_alpha = true;
        }
    }
    try std.testing.expect(saw_fractional_alpha);
}
test "terminal renderer places image z phases around terminal paint phases" {
    var a = [_]u32{'A'};
    var cells = [_]client.rich.Cell{cell(&a, 1, 0)};
    cells[0].background = .{ .kind = .rgb, .value = 0x112233 };
    cells[0].underline_color = .{ .kind = .rgb, .value = 0x445566 };
    cells[0].style_bits |= (1 << 7) | (1 << 8);
    var rows = [_]client.rich.Row{.{ .wrapped = false, .line_geometry = 0, .cells = &cells }};
    var images = [_]client.view.Image{.{ .image_id = 7, .generation = 9, .width = 1, .height = 1 }};
    var placements = [_]client.view.ImagePlacement{.{
        .image_id = 7,
        .generation = 3,
        .row = 0,
        .column = 0,
        .source_x = 0,
        .source_y = 0,
        .source_width = 1,
        .source_height = 1,
        .cell_x = 0,
        .cell_y = 0,
        .pixel_width = 10,
        .pixel_height = 20,
        .z = 0,
    }};
    var source = sourceSnapshot(&rows, 1);
    source.graphics = .{
        .generation = 11,
        .content_generation = 10,
        .cell_pixel_width = 10,
        .cell_pixel_height = 20,
        .images = &images,
        .placements = &placements,
    };
    const binding = terminal.ExternalImageBinding{
        .image_id = 7,
        .generation = 9,
        .resource = .{ .resource = try terminal.ResourceId.init(2), .generation = @fromBackingInt(9) },
    };
    const default_background = terminal.Color{ .r = 1, .g = 2, .b = 3, .a = 255 };
    const cell_background = terminal.Color{ .r = 0x11, .g = 0x22, .b = 0x33, .a = 255 };
    const decoration = terminal.Color{ .r = 0x44, .g = 0x55, .b = 0x66, .a = 255 };
    const threshold: i32 = std.math.minInt(i32) / 2;
    const cases = [_]struct { z: i32, phase: enum { below_cell_background, below_foreground, above_foreground } }{
        .{ .z = threshold - 1, .phase = .below_cell_background },
        .{ .z = threshold, .phase = .below_foreground },
        .{ .z = -1, .phase = .below_foreground },
        .{ .z = 0, .phase = .above_foreground },
    };

    for (cases) |case| {
        placements[0].z = case.z;
        const view = try client.view.project(std.testing.allocator, &source);
        defer client.view.deinit(view);
        const font = try terminalFont();
        defer font.deinit();
        var host = try Harness.init(std.testing.allocator, font, rendererConfig(16));
        defer host.deinit();
        const presented = try host.presentWithBindings(view, &.{binding});
        try std.testing.expectEqual(@as(usize, 1), presented.external.len);

        var default_index: ?usize = null;
        var cell_background_index: ?usize = null;
        var first_decoration_index: ?usize = null;
        var first_glyph_index: ?usize = null;
        var image_index: ?usize = null;
        for (presented.frame.commands, 0..) |command, index| switch (command) {
            .solid => |solid| {
                if (std.meta.eql(solid.color, default_background) and default_index == null) default_index = index;
                if (std.meta.eql(solid.color, cell_background) and cell_background_index == null) cell_background_index = index;
                if (std.meta.eql(solid.color, decoration) and first_decoration_index == null) first_decoration_index = index;
            },
            .alpha_mask => if (first_glyph_index == null) {
                first_glyph_index = index;
            },
            .rgba => image_index = index,
        };
        const default_at = default_index orelse return error.MissingDefaultBackground;
        const cell_background_at = cell_background_index orelse return error.MissingCellBackground;
        const decoration_at = first_decoration_index orelse return error.MissingDecoration;
        const glyph_at = first_glyph_index orelse return error.MissingAlpha;
        const image_at = image_index orelse return error.MissingRgba;
        try std.testing.expect(default_at < cell_background_at);
        try std.testing.expect(cell_background_at < decoration_at);
        try std.testing.expect(decoration_at < glyph_at);
        switch (case.phase) {
            .below_cell_background => {
                try std.testing.expect(default_at < image_at);
                try std.testing.expect(image_at < cell_background_at);
            },
            .below_foreground => {
                try std.testing.expect(cell_background_at < image_at);
                try std.testing.expect(image_at < decoration_at);
            },
            .above_foreground => try std.testing.expect(glyph_at < image_at),
        }
    }
}

test "terminal renderer external image residency is requested once and removed when absent" {
    var a = [_]u32{'A'};
    var cells = [_]client.rich.Cell{cell(&a, 1, 0)};
    var rows = [_]client.rich.Row{.{ .wrapped = false, .line_geometry = 0, .cells = &cells }};
    var images = [_]client.view.Image{.{ .image_id = 7, .generation = 9, .width = 2, .height = 2 }};
    var placements = [_]client.view.ImagePlacement{.{
        .image_id = 7,
        .generation = 9,
        .row = 0,
        .column = 0,
        .source_x = 0,
        .source_y = 0,
        .source_width = 2,
        .source_height = 2,
        .cell_x = 0,
        .cell_y = 0,
        .pixel_width = 10,
        .pixel_height = 20,
        .z = 0,
    }};
    var image_source = sourceSnapshot(&rows, 1);
    image_source.graphics = .{
        .generation = 1,
        .content_generation = 1,
        .cell_pixel_width = 10,
        .cell_pixel_height = 20,
        .images = &images,
        .placements = &placements,
    };
    const image_view = try client.view.project(std.testing.allocator, &image_source);
    defer client.view.deinit(image_view);
    const plain_source = sourceSnapshot(&rows, 1);
    const plain_view = try client.view.project(std.testing.allocator, &plain_source);
    defer client.view.deinit(plain_view);
    const font = try terminalFont();
    defer font.deinit();
    var host = try Harness.init(std.testing.allocator, font, rendererConfig(32));
    defer host.deinit();
    const binding = terminal.ExternalImageBinding{
        .image_id = 7,
        .generation = 9,
        .resource = .{ .resource = try terminal.ResourceId.init(2), .generation = @fromBackingInt(9) },
    };

    const with_image = try host.presentWithBindings(image_view, &.{binding});
    try std.testing.expectEqual(@as(usize, 1), with_image.external.len);
    try std.testing.expect(firstRgba(with_image.frame.commands) != null);
    const image_resource = with_image.external[0].resource;

    const same = try host.presentWithBindings(image_view, &.{binding});
    try std.testing.expectEqual(@as(usize, 0), same.external.len);

    const without = try host.present(plain_view);
    var removed = false;
    for (without.frame.removals) |value| {
        if (std.meta.eql(value, image_resource)) removed = true;
    }
    try std.testing.expect(removed);
    try std.testing.expect(firstRgba(without.frame.commands) == null);
}

test "terminal renderer rejected update invalidates frame until same renderer retries" {
    const font = try terminalFont();
    defer font.deinit();
    inline for (.{ false, true }) |borrowed| {
        var a = [_]u32{'A'};
        var b = [_]u32{'B'};
        var cells = [_]client.rich.Cell{cell(&a, 1, 0)};
        var rows = [_]client.rich.Row{.{ .wrapped = false, .line_geometry = 0, .cells = &cells }};
        var images = [_]client.view.Image{.{ .image_id = 7, .generation = 9, .width = 2, .height = 2 }};
        var placements = [_]client.view.ImagePlacement{.{
            .image_id = 7,
            .generation = 9,
            .row = 0,
            .column = 0,
            .source_x = 0,
            .source_y = 0,
            .source_width = 2,
            .source_height = 2,
            .cell_x = 0,
            .cell_y = 0,
            .pixel_width = 10,
            .pixel_height = 20,
            .z = 0,
        }};
        var source = sourceSnapshot(&rows, 1);
        source.graphics = .{
            .generation = 1,
            .content_generation = 1,
            .cell_pixel_width = 10,
            .cell_pixel_height = 20,
            .images = &images,
            .placements = &placements,
        };
        var binding = terminal.ExternalImageBinding{
            .image_id = 7,
            .generation = 9,
            .resource = .{ .resource = try terminal.ResourceId.init(2), .generation = @fromBackingInt(9) },
        };
        var host = try Harness.init(std.testing.allocator, font, rendererConfig(32));
        defer host.deinit();
        var rich = source.view();
        const owned_a = try client.view.projectView(std.testing.allocator, &rich);
        defer client.view.deinit(owned_a);
        const first = if (borrowed)
            try host.presentRichWithBindings(&rich, &.{binding})
        else
            try host.presentWithBindings(owned_a, &.{binding});
        const first_revision = first.frame.revision;
        const atlas_resource = first.frame.uploads[0].resource;
        const before = terminal.usage(host.renderer);

        // B changes drawing AND grows the atlas before the stale binding fails.
        cells[0] = cell(&b, 1, 0);
        images[0].generation = 10;
        rich = source.view();
        const owned_b = try client.view.projectView(std.testing.allocator, &rich);
        defer client.view.deinit(owned_b);
        try std.testing.expectError(error.InvalidImageBinding, if (borrowed)
            terminal.updateRichWithImageBindings(host.renderer, &rich, &.{binding})
        else
            terminal.updateWithImageBinding(host.renderer, owned_b, binding));
        const rejected = terminal.usage(host.renderer);
        try std.testing.expect(rejected.atlas_entries > before.atlas_entries);
        try std.testing.expectEqual(before.revision, rejected.revision);
        try std.testing.expectEqual(before.resource_generation, rejected.resource_generation);
        try std.testing.expectEqual(before.resource_high_water, rejected.resource_high_water);
        try std.testing.expectError(error.InvalidView, terminal.frame(host.renderer, host.residencies[0..host.residency_count], .{
            .uploads = host.uploads,
            .removals = host.removals,
            .commands = host.commands,
            .pixels = host.pixels,
        }));
        try std.testing.expectError(error.InvalidView, terminal.missingExternalResources(host.renderer, &.{}, &host.missing));

        // Matching the image is insufficient: its backend generation must advance.
        binding.generation = 10;
        try std.testing.expectError(error.InvalidImageBinding, if (borrowed)
            terminal.updateRichWithImageBindings(host.renderer, &rich, &.{binding})
        else
            terminal.updateWithImageBindings(host.renderer, owned_b, &.{binding}));
        binding.resource.generation = @fromBackingInt(10);
        const retry = if (borrowed)
            try host.presentRichWithBindings(&rich, &.{binding})
        else
            try host.presentWithBindings(owned_b, &.{binding});
        try std.testing.expectEqual(first_revision + 1, retry.frame.revision);
        try std.testing.expectEqual(@as(usize, 1), retry.external.len);
        try std.testing.expectEqual(binding.resource, retry.external[0].resource);
        try std.testing.expectEqual(binding.resource, firstRgba(retry.frame.commands).?.resource.resource);
        try std.testing.expectEqual(@as(usize, 1), retry.frame.uploads.len);
        try std.testing.expectEqual(atlas_resource.resource, retry.frame.uploads[0].resource.resource);
        try std.testing.expectEqual(@backingInt(atlas_resource.generation) + 1, @backingInt(retry.frame.uploads[0].resource.generation));
        try std.testing.expectEqual(@as(usize, 0), retry.frame.removals.len);

        // The no-binding entrypoints obey the same invalidation contract.
        try std.testing.expectError(error.InvalidImageBinding, if (borrowed)
            terminal.updateRich(host.renderer, &rich)
        else
            terminal.update(host.renderer, owned_b));
        try std.testing.expectError(error.InvalidView, host.finishPresent());
        const same = if (borrowed)
            try host.presentRichWithBindings(&rich, &.{binding})
        else
            try host.presentWithBindings(owned_b, &.{binding});
        try std.testing.expectEqual(first_revision + 2, same.frame.revision);
        try std.testing.expectEqual(@as(usize, 0), same.frame.uploads.len);
        try std.testing.expectEqual(@as(usize, 0), same.external.len);
    }
}

test "terminal renderer block cursor is final presentation not compositor topology" {
    var scalar = [_]u32{'A'};
    var cells = [_]client.rich.Cell{cell(&scalar, 1, 0)};
    var rows = [_]client.rich.Row{.{ .wrapped = false, .line_geometry = 0, .cells = &cells }};
    var source = sourceSnapshot(&rows, 1);
    source.begin.terminal.cursor_visible = true;
    source.presentation.presence_bits = 1;
    source.presentation.cursor = .{ .r = 9, .g = 8, .b = 7, .a = 255 };
    source.presentation.cursor_text = null;
    const view = try client.view.project(std.testing.allocator, &source);
    defer client.view.deinit(view);
    const font = try terminalFont();
    defer font.deinit();
    var host = try Harness.init(std.testing.allocator, font, rendererConfig(32));
    defer host.deinit();
    const frame = (try host.present(view)).frame;
    var cursor_background = false;
    var recolored = false;
    for (frame.commands) |command| switch (command) {
        .solid => |value| if (std.meta.eql(value.color, terminal.Color{ .r = 9, .g = 8, .b = 7, .a = 255 })) {
            cursor_background = true;
        },
        .alpha_mask => |value| if (value.destination.x == 0 and value.destination.y <= 20 and
            std.meta.eql(value.color, terminal.Color{ .r = 1, .g = 2, .b = 3, .a = 255 }))
        {
            recolored = true;
        },
        else => {},
    };
    try std.testing.expect(cursor_background);
    try std.testing.expect(recolored);
}

test "dense 40x120 terminal renderer is bounded and recovers from command exhaustion" {
    const row_count: usize = 40;
    const column_count: usize = 120;
    const cell_count = row_count * column_count;
    const command_count = cell_count + 1;
    var scalar = [_]u32{'A'};
    const cells = try std.testing.allocator.alloc(client.rich.Cell, cell_count);
    defer std.testing.allocator.free(cells);
    for (cells) |*value| value.* = cell(&scalar, 1, 0);
    const rows = try std.testing.allocator.alloc(client.rich.Row, row_count);
    defer std.testing.allocator.free(rows);
    for (rows, 0..) |*row, index| {
        const first = index * column_count;
        row.* = .{ .wrapped = false, .line_geometry = 0, .cells = cells[first .. first + column_count] };
    }
    const source = sourceSnapshot(rows, column_count);
    const view = try client.view.project(std.testing.allocator, &source);
    defer client.view.deinit(view);
    const font = try terminalFont();
    defer font.deinit();

    const limited = try terminal.initPrivate(std.testing.allocator, terminal.FontFaces.single(font), rendererConfig(command_count - 1));
    defer terminal.deinit(limited);
    try std.testing.expectError(error.CommandLimit, terminal.update(limited, view));
    const failed = terminal.usage(limited);
    try std.testing.expectEqual(@as(u64, 0), failed.revision);
    try std.testing.expectEqual(@as(u64, 0), failed.resource_generation);

    var lazy_config = rendererConfig(64);
    lazy_config.command_limit = command_count;
    const lazy = try terminal.initPrivate(std.testing.allocator, terminal.FontFaces.single(font), lazy_config);
    defer terminal.deinit(lazy);
    try terminal.update(lazy, view);
    try std.testing.expect(terminal.usage(lazy).command_capacity >= command_count);
    try std.testing.expect(terminal.usage(lazy).command_capacity <= lazy_config.command_limit);

    var host = try Harness.init(std.testing.allocator, font, rendererConfig(command_count));
    defer host.deinit();
    const frame = (try host.present(view)).frame;
    try std.testing.expectEqual(command_count, frame.commands.len);
    try std.testing.expectEqual(@as(u64, 1), frame.revision);
}

test "terminal renderer borrowed rich and owned view produce identical final frame" {
    var scalar_zero = [_]u32{'='};
    var scalar_one = [_]u32{'>'};
    var scalar_two = [_]u32{'A'};
    var scalar_three = [_]u32{'B'};
    var cells = [_]client.rich.Cell{
        cell(&scalar_zero, 1, 0),
        cell(&scalar_one, 1, 0),
        cell(&scalar_two, 1, 0),
        cell(&scalar_three, 1, 0),
    };
    var rows = [_]client.rich.Row{.{
        .wrapped = false,
        .line_geometry = 0,
        .cells = &cells,
    }};
    var images = [_]client.view.Image{.{
        .image_id = 7,
        .generation = 9,
        .width = 1,
        .height = 1,
    }};
    var placements = [_]client.view.ImagePlacement{.{
        .image_id = 7,
        .generation = 3,
        .row = 0,
        .column = 0,
        .source_x = 0,
        .source_y = 0,
        .source_width = 1,
        .source_height = 1,
        .cell_x = 0,
        .cell_y = 0,
        .pixel_width = 10,
        .pixel_height = 20,
        .z = 0,
    }};
    var source = sourceSnapshot(&rows, 4);
    source.begin.revision = 41;
    source.begin.terminal.revision = 39;
    source.graphics = .{
        .generation = 11,
        .content_generation = 10,
        .cell_pixel_width = 10,
        .cell_pixel_height = 20,
        .images = &images,
        .placements = &placements,
    };
    const binding = terminal.ExternalImageBinding{
        .image_id = 7,
        .generation = 9,
        .resource = .{
            .resource = try terminal.ResourceId.init(2),
            .generation = @fromBackingInt(9),
        },
    };
    const rich = source.view();
    const owned = try client.view.projectView(std.testing.allocator, &rich);
    defer client.view.deinit(owned);

    const font = try terminalFont();
    defer font.deinit();
    var owned_host = try Harness.init(std.testing.allocator, font, rendererConfig(128));
    defer owned_host.deinit();
    var rich_host = try Harness.init(std.testing.allocator, font, rendererConfig(128));
    defer rich_host.deinit();

    const owned_presented = try owned_host.presentWithBindings(owned, &.{binding});
    const rich_presented = try rich_host.presentRichWithBindings(&rich, &.{binding});
    try std.testing.expectEqualDeep(owned_presented.external, rich_presented.external);
    try std.testing.expectEqualDeep(owned_presented.frame, rich_presented.frame);
}

test "terminal renderer same-index changed rows equal complete final commands" {
    var baseline_scalars = [_][1]u32{ .{'A'}, .{'B'}, .{'C'}, .{'D'}, .{'E'}, .{'F'} };
    var baseline_cells: [6][1]client.rich.Cell = undefined;
    var baseline_rows: [6]client.rich.Row = undefined;
    for (&baseline_cells, &baseline_rows, 0..) |*cells, *row, index| {
        cells.* = .{cell(&baseline_scalars[index], 1, 0)};
        row.* = .{ .wrapped = false, .line_geometry = 0, .cells = cells };
    }
    var baseline_source = sourceSnapshot(&baseline_rows, 1);
    baseline_source.begin.revision = 20;
    baseline_source.begin.terminal.revision = 20;
    var baseline_rich = baseline_source.view();
    var baseline_changed: [6]bool = @splat(true);
    baseline_rich.changed_rows = &baseline_changed;
    baseline_rich.changed_rows_base_revision = null;
    const baseline_view = try client.view.projectView(std.testing.allocator, &baseline_rich);
    defer client.view.deinit(baseline_view);

    const font = try terminalFont();
    defer font.deinit();
    var cached_config = rendererConfig(64);
    cached_config.incremental_row_capacity = 6;
    cached_config.incremental_command_capacity = 32;
    var cached = try Harness.init(std.testing.allocator, font, cached_config);
    defer cached.deinit();
    var stale = try Harness.init(std.testing.allocator, font, cached_config);
    defer stale.deinit();
    var complete = try Harness.init(std.testing.allocator, font, rendererConfig(64));
    defer complete.deinit();
    const cached_base = try cached.present(baseline_view);
    const cached_scene_base = terminal.rowScene(cached.renderer) orelse return error.TestExpectedRowScene;
    try std.testing.expectEqual(terminal.RowSceneKind.baseline, cached_scene_base.kind);
    try std.testing.expectEqual(@as(?u64, null), cached_scene_base.base_revision);
    try std.testing.expectEqual(@as(u64, 1), cached_scene_base.revision);
    try std.testing.expectEqual(terminal.Size{ .width = 10, .height = 120 }, cached_scene_base.surface);
    try std.testing.expectEqual(terminal.Size{ .width = 10, .height = 20 }, cached_scene_base.cell_size);
    try std.testing.expectEqual(terminal.Color{ .r = 1, .g = 2, .b = 3, .a = 0xff }, cached_scene_base.background);
    try std.testing.expectEqual(@as(usize, 6), cached_scene_base.rows.len);
    try std.testing.expectEqual(@as(usize, 6), cached_scene_base.repairs.len);
    for (cached_scene_base.repairs) |repair| try std.testing.expect(repair);
    const stale_base = try stale.present(baseline_view);
    const complete_base = try complete.present(baseline_view);
    try std.testing.expectEqualDeep(cached_base.frame.commands, complete_base.frame.commands);
    try std.testing.expectEqualDeep(stale_base.frame.commands, complete_base.frame.commands);

    var changed_scalars = [_][1]u32{ .{'A'}, .{'B'}, .{'X'}, .{'D'}, .{'E'}, .{'F'} };
    var changed_cells: [6][1]client.rich.Cell = undefined;
    var changed_rows: [6]client.rich.Row = undefined;
    for (&changed_cells, &changed_rows, 0..) |*cells, *row, index| {
        cells.* = .{cell(&changed_scalars[index], 1, 0)};
        row.* = .{ .wrapped = false, .line_geometry = 0, .cells = cells };
    }
    var changed_source = sourceSnapshot(&changed_rows, 1);
    changed_source.begin.revision = 21;
    changed_source.begin.terminal.revision = 21;
    var changed_rich = changed_source.view();
    var changed_mask = [_]bool{ false, false, true, false, false, false };
    changed_rich.changed_rows = &changed_mask;
    changed_rich.changed_rows_base_revision = 20;
    const changed_view = try client.view.projectView(std.testing.allocator, &changed_rich);
    defer client.view.deinit(changed_view);
    try std.testing.expect(client.view.rowShift(changed_view) == null);
    try std.testing.expectEqualSlices(bool, &changed_mask, client.view.changedRows(changed_view).?);

    const cached_changed = try cached.present(changed_view);
    const cached_scene_changed = terminal.rowScene(cached.renderer) orelse return error.TestExpectedRowScene;
    try std.testing.expectEqual(terminal.RowSceneKind.patch, cached_scene_changed.kind);
    try std.testing.expectEqual(@as(?u64, 1), cached_scene_changed.base_revision);
    try std.testing.expectEqual(@as(u64, 2), cached_scene_changed.revision);
    try std.testing.expectEqualSlices(bool, &changed_mask, cached_scene_changed.repairs);
    const complete_changed = try complete.present(changed_view);
    try std.testing.expectEqualDeep(cached_changed.frame.commands, complete_changed.frame.commands);

    // `stale` deliberately never accepted revision 21. Revision 22's mask is
    // relative to 21 and says row 2 is unchanged. Reusing stale revision-20
    // commands would render C instead of X, so exact baseline identity must
    // force a complete projection and re-prime the cache.
    var coalesced_source = sourceSnapshot(&changed_rows, 1);
    coalesced_source.begin.revision = 22;
    coalesced_source.begin.terminal.revision = 22;
    var coalesced_rich = coalesced_source.view();
    var coalesced_mask: [6]bool = @splat(false);
    coalesced_rich.changed_rows = &coalesced_mask;
    coalesced_rich.changed_rows_base_revision = 21;
    const coalesced_view = try client.view.projectView(std.testing.allocator, &coalesced_rich);
    defer client.view.deinit(coalesced_view);
    const stale_coalesced = try stale.present(coalesced_view);
    const stale_scene = terminal.rowScene(stale.renderer) orelse return error.TestExpectedRowScene;
    try std.testing.expectEqual(terminal.RowSceneKind.baseline, stale_scene.kind);
    try std.testing.expectEqual(@as(?u64, null), stale_scene.base_revision);
    try std.testing.expectEqual(@as(u64, 2), stale_scene.revision);
    const complete_coalesced = try complete.present(coalesced_view);
    try std.testing.expectEqualDeep(stale_coalesced.frame.commands, complete_coalesced.frame.commands);
}

test "incremental cached row reuse grows complete command storage instead of rejecting view" {
    const row_count: usize = 6;
    const column_count: usize = 4;
    var glyph_scalar = [_]u32{'A'};
    var changed_scalar = [_]u32{'B'};
    var space_scalar = [_]u32{' '};

    var baseline_cells: [row_count][column_count]client.rich.Cell = undefined;
    var baseline_rows: [row_count]client.rich.Row = undefined;
    for (&baseline_cells, &baseline_rows) |*cells, *row| {
        cells[0] = cell(&glyph_scalar, 1, 0);
        for (cells[1..]) |*value| value.* = cell(&space_scalar, 1, 0);
        row.* = .{ .wrapped = false, .line_geometry = 0, .cells = cells };
    }
    var baseline_source = sourceSnapshot(&baseline_rows, column_count);
    baseline_source.begin.revision = 30;
    baseline_source.begin.terminal.revision = 30;
    var baseline_rich = baseline_source.view();
    var baseline_changed: [row_count]bool = @splat(true);
    baseline_rich.changed_rows = &baseline_changed;
    const baseline_view = try client.view.projectView(std.testing.allocator, &baseline_rich);
    defer client.view.deinit(baseline_view);

    const font = try terminalFont();
    defer font.deinit();
    var config = rendererConfig(row_count + 1);
    config.command_limit = 32;
    config.incremental_row_capacity = row_count;
    config.incremental_command_capacity = 32;
    var cached = try Harness.init(std.testing.allocator, font, config);
    defer cached.deinit();
    var complete = try Harness.init(std.testing.allocator, font, rendererConfig(32));
    defer complete.deinit();

    const baseline_cached = try cached.present(baseline_view);
    const baseline_complete = try complete.present(baseline_view);
    try std.testing.expectEqualDeep(baseline_complete.frame.commands, baseline_cached.frame.commands);
    try std.testing.expectEqual(@as(usize, row_count + 1), terminal.usage(cached.renderer).command_capacity);

    var changed_cells = baseline_cells;
    for (&changed_cells[0]) |*value| value.* = cell(&changed_scalar, 1, 0);
    var changed_rows: [row_count]client.rich.Row = undefined;
    for (&changed_cells, &changed_rows) |*cells, *row|
        row.* = .{ .wrapped = false, .line_geometry = 0, .cells = cells };
    var changed_source = sourceSnapshot(&changed_rows, column_count);
    changed_source.begin.revision = 31;
    changed_source.begin.terminal.revision = 31;
    var changed_rich = changed_source.view();
    var changed_mask = [_]bool{ true, false, false, false, false, false };
    changed_rich.changed_rows = &changed_mask;
    changed_rich.changed_rows_base_revision = 30;
    const changed_view = try client.view.projectView(std.testing.allocator, &changed_rich);
    defer client.view.deinit(changed_view);

    const changed_complete = try complete.present(changed_view);
    const changed_cached = try cached.present(changed_view);
    try std.testing.expectEqualDeep(changed_complete.frame.commands, changed_cached.frame.commands);
    try std.testing.expect(terminal.usage(cached.renderer).command_capacity > row_count + 1);
    try std.testing.expect(terminal.usage(cached.renderer).command_capacity <= config.command_limit);
}

test "terminal renderer incremental rows equal complete final commands" {
    var baseline_scalars = [_][1]u32{ .{'A'}, .{'B'}, .{'C'}, .{'D'}, .{'E'}, .{'F'} };
    var baseline_cells: [6][1]client.rich.Cell = undefined;
    var baseline_rows: [6]client.rich.Row = undefined;
    for (&baseline_cells, &baseline_rows, 0..) |*cells, *row, index| {
        cells.* = .{cell(&baseline_scalars[index], 1, 0)};
        row.* = .{ .wrapped = false, .line_geometry = 0, .cells = cells };
    }
    var baseline_source = sourceSnapshot(&baseline_rows, 1);
    baseline_source.begin.revision = 30;
    baseline_source.begin.terminal.revision = 30;
    var baseline_rich = baseline_source.view();
    var baseline_changed: [6]bool = @splat(true);
    baseline_rich.changed_rows = &baseline_changed;
    const baseline_view = try client.view.projectView(std.testing.allocator, &baseline_rich);
    defer client.view.deinit(baseline_view);
    const font = try terminalFont();
    defer font.deinit();
    var cached_config = rendererConfig(64);
    cached_config.incremental_row_capacity = 6;
    cached_config.incremental_command_capacity = 32;
    var cached = try Harness.init(std.testing.allocator, font, cached_config);
    defer cached.deinit();
    var complete = try Harness.init(std.testing.allocator, font, rendererConfig(64));
    defer complete.deinit();
    const cached_base = try cached.present(baseline_view);
    const complete_base = try complete.present(baseline_view);
    try std.testing.expectEqualDeep(cached_base.frame.commands, complete_base.frame.commands);

    var shifted_scalars = [_][1]u32{ .{'B'}, .{'C'}, .{'D'}, .{'X'}, .{'F'}, .{'G'} };
    var shifted_cells: [6][1]client.rich.Cell = undefined;
    var shifted_rows: [6]client.rich.Row = undefined;
    for (&shifted_cells, &shifted_rows, 0..) |*cells, *row, index| {
        cells.* = .{cell(&shifted_scalars[index], 1, 0)};
        row.* = .{ .wrapped = false, .line_geometry = 0, .cells = cells };
    }
    var shifted_source = sourceSnapshot(&shifted_rows, 1);
    shifted_source.begin.revision = 31;
    shifted_source.begin.terminal.revision = 31;
    var shifted_rich = shifted_source.view();
    var changed = [_]bool{ false, false, false, true, false, true };
    shifted_rich.changed_rows = &changed;
    shifted_rich.changed_rows_base_revision = 30;
    shifted_rich.row_shift = 1;
    const shifted_view = try client.view.projectView(std.testing.allocator, &shifted_rich);
    defer client.view.deinit(shifted_view);
    const cached_shifted = try cached.present(shifted_view);
    const complete_shifted = try complete.present(shifted_view);
    try std.testing.expectEqualDeep(cached_shifted.frame.commands, complete_shifted.frame.commands);

    // Reuse is now primed. A late failure must discard eligibility, not let a
    // retry shift the cached rows a second time from the wrong base.
    const unused_binding = terminal.ExternalImageBinding{
        .image_id = 7,
        .generation = 1,
        .resource = .{ .resource = try terminal.ResourceId.init(2), .generation = @fromBackingInt(1) },
    };
    try std.testing.expectError(error.InvalidImageBinding, terminal.updateWithImageBinding(cached.renderer, shifted_view, unused_binding));
    try std.testing.expectError(error.InvalidView, cached.finishPresent());
    const retried = try cached.present(shifted_view);
    try std.testing.expectEqualDeep(complete_shifted.frame.commands, retried.frame.commands);
}

test "terminal renderer construction releases every staged allocation and validates bounds" {
    const font = try terminalFont();
    defer font.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, constructTerminalrenderer, .{font});
    var invalid = rendererConfig(64);
    invalid.cell_size.width = 0;
    try std.testing.expectError(error.InvalidConfig, terminal.initPrivate(std.testing.failing_allocator, terminal.FontFaces.single(font), invalid));
    invalid = rendererConfig(0);
    try std.testing.expectError(error.InvalidConfig, terminal.initPrivate(std.testing.failing_allocator, terminal.FontFaces.single(font), invalid));
}

const VT = @import("howl_vt").Terminal;

// Independent test-only rich fixture. Production never constructs client rows,
// cells, scalar banks, or a snapshot envelope for the direct observation path.

fn feedCanonical(owner: *VT, bytes: []const u8) !void {
    const result = try owner.feed(bytes);
    try std.testing.expect(result.stateChanged());
}

fn richFixture(allocator: std.mem.Allocator, observation: *const VT.Observation, history: u32) !client.rich.Snapshot {
    const view = observation.semanticView(history);
    const rows = try allocator.alloc(client.rich.Row, view.rows);
    for (rows, 0..) |*row, y| {
        row.* = .{
            .wrapped = view.rowWrapped(@intCast(y)),
            .line_geometry = @backingInt(view.lineGeometry(@intCast(y))),
            .cells = try allocator.alloc(client.rich.Cell, view.cols),
        };
        for (row.cells, 0..) |*out, x| {
            const value = view.cellInfoAt(@intCast(y), @intCast(x));
            var scalar_buffer: [24]u21 = undefined;
            const scalars = if (value.x == 0 and value.y == 0)
                view.cellScalarsAt(@intCast(y), @intCast(x), &scalar_buffer)
            else
                &.{};
            const copied = try allocator.alloc(u32, scalars.len);
            for (copied, scalars) |*dest, scalar| dest.* = scalar;
            out.* = cell(&.{}, value.width, value.x);
            out.scalars = copied;
            out.height = value.height;
            out.y = value.y;
            out.subscale_n = value.subscale_n;
            out.subscale_d = value.subscale_d;
            out.vertical_align = value.vertical_align;
            out.horizontal_align = value.horizontal_align;
            out.semantic_width = value.semantic_width;
            out.font = value.attrs.font;
            out.baseline = @backingInt(value.attrs.baseline);
            out.underline_style = @backingInt(value.attrs.underline_style);
            out.protection = @backingInt(value.attrs.protected);
            out.link_id = value.attrs.link_id;
            out.style_bits = 0;
            inline for (.{ "bold", "dim", "italic", "blink", "blink_fast", "reverse", "invisible", "underline", "strikethrough" }, 0..) |name, bit| {
                if (@field(value.attrs, name)) out.style_bits |= @as(u16, 1) << bit;
            }
            out.foreground = fixtureColor(value.attrs.fg);
            out.background = fixtureColor(value.attrs.bg);
            out.underline_color = fixtureColor(value.attrs.underline_color);
        }
    }
    var source = sourceSnapshot(rows, view.cols);
    source.begin.terminal.history_offset = view.history_offset;
    source.begin.terminal.history_count = view.history_count;
    source.begin.terminal.history_row_base = view.history_row_base;
    source.begin.terminal.cursor_row = view.cursor_row;
    source.begin.terminal.cursor_column = view.cursor_col;
    source.begin.terminal.cursor_visible = view.cursor_visible;
    source.begin.terminal.cursor_blink = view.cursor_blink;
    source.begin.terminal.cursor_shape = @backingInt(view.cursor_shape);
    source.begin.terminal.alternate_screen = view.is_alternate_screen;
    const colors = observation.presentation();
    for (&source.presentation.palette, colors.palette) |*out, color| out.* = fixtureRgba(color);
    source.presentation.foreground = fixtureRgba(colors.foreground);
    source.presentation.background = fixtureRgba(colors.background);
    source.presentation.cursor = if (colors.cursor) |color| fixtureRgba(color) else null;
    source.presentation.cursor_text = if (colors.cursor_text) |color| fixtureRgba(color) else null;
    source.presentation.reverse_screen = colors.reverse_screen;
    source.presentation.flags = @intFromBool(colors.reverse_screen);
    source.presentation.presence_bits = @as(u8, @intFromBool(colors.cursor != null)) |
        (@as(u8, @intFromBool(colors.cursor_text != null)) << 1);
    const images = observation.images(history);
    source.graphics.generation = images.generation;
    source.graphics.content_generation = images.content_generation;
    source.graphics.cell_pixel_width = images.cell_pixel_width;
    source.graphics.cell_pixel_height = images.cell_pixel_height;
    source.graphics.images = try allocator.alloc(client.view.Image, images.imageCount());
    for (source.graphics.images, 0..) |*out, index| {
        const image = images.image(index).?;
        out.* = .{ .image_id = image.id, .generation = image.generation, .width = image.width, .height = image.height };
    }
    const placements = try allocator.alloc(client.view.ImagePlacement, images.placementCount());
    var count: usize = 0;
    for (0..images.placementCount()) |index| {
        const place = images.placement(index) orelse continue;
        placements[count] = .{
            .image_id = place.image_id,
            .generation = place.generation,
            .row = place.row,
            .column = place.col,
            .source_x = place.source_x,
            .source_y = place.source_y,
            .source_width = place.source_width,
            .source_height = place.source_height,
            .cell_x = place.cell_x,
            .cell_y = place.cell_y,
            .pixel_width = place.pixel_width,
            .pixel_height = place.pixel_height,
            .z = place.z,
        };
        count += 1;
    }
    source.graphics.placements = placements[0..count];
    var image_count: usize = 0;
    for (source.graphics.images) |image| {
        for (source.graphics.placements) |place| {
            if (place.image_id == image.image_id) {
                source.graphics.images[image_count] = image;
                image_count += 1;
                break;
            }
        }
    }
    source.graphics.images = source.graphics.images[0..image_count];
    return source;
}

fn fixtureColor(color: VT.Color) client.view.TextColor {
    return .{ .kind = @fromBackingInt(@intCast(@backingInt(color.kind))), .value = color.value };
}
fn fixtureRgba(color: VT.Rgb) client.rich.Rgba {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
}

fn directConfig() terminal.Config {
    var config = rendererConfig(2048);
    config.shape_cache = .{ .entry_capacity = 128, .scalar_capacity = 1024, .glyph_capacity = 1024, .max_sequence_scalars = 24 };
    config.atlas = .{ .width = 512, .height = 512, .entry_capacity = 128 };
    config.shaped_capacity = 128;
    return config;
}

fn expectDirectEquivalent(bytes: []const u8, history: u32) !void {
    var owner = try VT.initWithHistory(std.testing.allocator, 4, 12, 8);
    defer owner.deinit();
    try owner.setCellPixelSize(10, 20);
    try feedCanonical(&owner, bytes);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try richFixture(arena.allocator(), owner.observation(), history);
    const rich = fixture.view();
    const owned = try client.view.projectView(std.testing.allocator, &rich);
    defer client.view.deinit(owned);
    const font = try terminalFont();
    defer font.deinit();
    var direct = try Harness.init(std.testing.allocator, font, directConfig());
    defer direct.deinit();
    var borrowed = try Harness.init(std.testing.allocator, font, directConfig());
    defer borrowed.deinit();
    var independent = try Harness.init(std.testing.allocator, font, directConfig());
    defer independent.deinit();
    var bindings: [terminal.maximum_external_images]terminal.ExternalImageBinding = undefined;
    for (fixture.graphics.images, 0..) |image, index| bindings[index] = .{
        .image_id = image.image_id,
        .generation = image.generation,
        .resource = .{ .resource = try terminal.ResourceId.init(index + 2), .generation = @fromBackingInt(image.generation) },
    };
    const bound = bindings[0..fixture.graphics.images.len];
    for (0..2) |pass| {
        try terminal.updateObservation(direct.renderer, owner.observation(), history, bound);
        // On the second pass the frame is built AFTER VT mutation. This must not change the
        // commands, scalar keys, atlas pixels, or external generation metadata.
        if (pass == 1) try feedCanonical(&owner, "\x1bcZ");
        const actual = try direct.finishPresent();
        const expected = try borrowed.presentRichWithBindings(&rich, bound);
        const owned_frame = try independent.presentWithBindings(owned, bound);
        try std.testing.expectEqualDeep(expected, actual);
        try std.testing.expectEqualDeep(owned_frame, actual);
        if (pass == 1) try std.testing.expectEqual(@as(usize, 0), actual.frame.uploads.len);
    }
}

test "terminal renderer canonical plain and contextual text equals rich and owned final frames" {
    try expectDirectEquivalent("Hello => !=", 0);
}

test "terminal renderer canonical combining sidecars wide continuations and DEC geometry equal rich" {
    try expectDirectEquivalent("a\u{301}\u{302}\u{303}\u{304}\u{305} \u{754c}\r\n\x1b#6AB\r\n\x1b#3CD\r\n\x1b#4CD", 0);
    try expectDirectEquivalent("a\u{300}\u{301}\u{302}\u{303}\u{304}\u{305}\u{306}\u{307}\u{308}\u{309}\u{30a}\u{30b}\u{30c}\u{30d}\u{30e}\u{30f}\u{310}\u{311}\u{312}\u{313}\u{314}\u{315}\u{316}", 0);
}

test "terminal renderer canonical palette RGB reverse decorations and cursor equal rich" {
    try expectDirectEquivalent("\x1b]4;1;#123456\x07\x1b]10;#abcdee\x07\x1b]12;#654321\x07\x1b[31;44;1;2;4;9mAB\x1b[0;38;2;90;80;70;48;2;20;30;40mC\x1b[7mD\x1b[?5h\x1b[6 q", 0);
}

test "terminal renderer canonical projected history and alternate screen equal rich" {
    try expectDirectEquivalent("A\r\nB\r\nC\r\nD\r\nE\r\nF", 2);
    try expectDirectEquivalent("old\x1b[?1049hnew", 0);
}

test "terminal renderer canonical Kitty images retain exact bindings and equal rich" {
    try expectDirectEquivalent("A\x1b_Ga=T,f=32,s=1,v=1,i=7,c=1,r=1,z=-1;/////w==\x1b\\", 0);
    // Retained primary placements become sparse/invisible in alternate screen.
    try expectDirectEquivalent("\x1b_Ga=T,f=32,s=1,v=1,i=7;/////w==\x1b\\\x1b[?1049hB", 0);
}

test "terminal renderer canonical image limit counts visible resources only" {
    var owner = try VT.init(std.testing.allocator, 2, 12);
    defer owner.deinit();
    try owner.setCellPixelSize(10, 20);
    inline for (1..9) |image_id| {
        var sequence: [96]u8 = undefined;
        const bytes = try std.fmt.bufPrint(
            &sequence,
            "\x1b_Ga=t,f=32,s=1,v=1,i={d};/////w==\x1b\\",
            .{image_id},
        );
        try feedCanonical(&owner, bytes);
    }
    try feedCanonical(&owner, "\x1b_Ga=T,f=32,s=1,v=1,i=9;/////w==\x1b\\");
    const images = owner.observation().images(0);
    try std.testing.expect(images.imageCount() > terminal.maximum_external_images);
    try std.testing.expectEqual(@as(usize, 1), images.placementCount());
    const visible = images.image(images.imageCount() - 1).?;
    const font = try terminalFont();
    defer font.deinit();
    var host = try Harness.init(std.testing.allocator, font, directConfig());
    defer host.deinit();
    var binding_storage: [terminal.maximum_external_images]terminal.ExternalImageBinding = undefined;
    const bindings = try terminal.planObservationImageBindings(
        &.{},
        terminal.usage(host.renderer),
        owner.observation(),
        0,
        &binding_storage,
    );
    try std.testing.expectEqual(@as(usize, 1), bindings.len);
    const binding = bindings[0];
    try std.testing.expectEqual(visible.id, binding.image_id);
    try std.testing.expectEqual(visible.generation, binding.generation);
    try std.testing.expectEqual(@as(u64, 2), try binding.resource.resource.identity());
    try terminal.updateObservation(host.renderer, owner.observation(), 0, bindings);
    const presented = try host.finishPresent();
    try std.testing.expectEqual(@as(usize, 1), presented.external.len);
    try std.testing.expectEqual(binding.resource, presented.external[0].resource);
}

test "terminal renderer canonical image planner preserves identity across exact generations" {
    var owner = try VT.init(std.testing.allocator, 2, 4);
    defer owner.deinit();
    try owner.setCellPixelSize(10, 20);
    try feedCanonical(&owner, "A\x1b_Ga=T,f=32,s=1,v=1,i=7;/////w==\x1b\\");
    const font = try terminalFont();
    defer font.deinit();
    var host = try Harness.init(std.testing.allocator, font, directConfig());
    defer host.deinit();

    var first_storage: [terminal.maximum_external_images]terminal.ExternalImageBinding = undefined;
    const first = try terminal.planObservationImageBindings(
        &.{},
        terminal.usage(host.renderer),
        owner.observation(),
        0,
        &first_storage,
    );
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqual(@as(u64, 2), try first[0].resource.resource.identity());
    try terminal.updateObservation(host.renderer, owner.observation(), 0, first);
    const first_presented = try host.finishPresent();
    try std.testing.expectEqual(terminal.usage(host.renderer).revision, first_presented.frame.revision);

    try feedCanonical(&owner, "\x1b_Ga=t,f=32,s=1,v=1,i=7;AAAA/w==\x1b\\");
    const changed = owner.observation().images(0).image(0).?;
    try std.testing.expect(changed.generation > first[0].generation);
    var next_storage: [terminal.maximum_external_images]terminal.ExternalImageBinding = undefined;
    const next = try terminal.planObservationImageBindings(
        first,
        terminal.usage(host.renderer),
        owner.observation(),
        0,
        &next_storage,
    );
    try std.testing.expectEqual(@as(usize, 1), next.len);
    try std.testing.expectEqual(first[0].image_id, next[0].image_id);
    try std.testing.expectEqual(first[0].resource.resource, next[0].resource.resource);
    try std.testing.expectEqual(changed.generation, next[0].generation);
    try std.testing.expectEqual(changed.generation, @backingInt(next[0].resource.generation));

    var stale = next[0];
    stale.generation = try std.math.add(u64, next[0].generation, 1);
    try std.testing.expectError(
        error.InvalidImageBinding,
        terminal.planObservationImageBindings(
            &.{stale},
            terminal.usage(host.renderer),
            owner.observation(),
            0,
            &next_storage,
        ),
    );
}

test "terminal renderer canonical stale image generations reject atomically and retry" {
    var owner = try VT.init(std.testing.allocator, 2, 4);
    defer owner.deinit();
    try owner.setCellPixelSize(10, 20);
    try feedCanonical(&owner, "A\x1b_Ga=T,f=32,s=1,v=1,i=7;/////w==\x1b\\");
    const font = try terminalFont();
    defer font.deinit();
    var host = try Harness.init(std.testing.allocator, font, directConfig());
    defer host.deinit();
    const images = owner.observation().images(0);
    try std.testing.expectEqual(@as(usize, 1), images.imageCount());
    try std.testing.expectEqual(@as(usize, 1), images.placementCount());
    const original = images.image(0).?;
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, original.pixels);
    var binding: terminal.ExternalImageBinding = .{
        .image_id = original.id,
        .generation = original.generation,
        .resource = .{ .resource = try terminal.ResourceId.init(2), .generation = @fromBackingInt(10) },
    };
    try terminal.updateObservation(host.renderer, owner.observation(), 0, &.{binding});
    const first = try host.finishPresent();
    const revision = first.frame.revision;
    try std.testing.expectEqual(binding.resource, firstRgba(first.frame.commands).?.resource.resource);
    try feedCanonical(&owner, "\x1b_Ga=t,f=32,s=1,v=1,i=7;AAAA/w==\x1b\\");
    const changed = owner.observation().images(0).image(0).?;
    try std.testing.expect(changed.generation > original.generation);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, changed.pixels);
    // Stale canonical generation cannot resolve the required image.
    try std.testing.expectError(error.InvalidImageBinding, terminal.updateObservation(host.renderer, owner.observation(), 0, &.{binding}));
    try std.testing.expectError(error.InvalidView, host.finishPresent());
    binding.generation = changed.generation;
    // Updating the canonical generation alone cannot reuse stale GPU residency.
    try std.testing.expectError(error.InvalidImageBinding, terminal.updateObservation(host.renderer, owner.observation(), 0, &.{binding}));
    try std.testing.expectError(error.InvalidView, host.finishPresent());
    binding.resource.generation = @fromBackingInt(11);
    try terminal.updateObservation(host.renderer, owner.observation(), 0, &.{binding});
    const retried = try host.finishPresent();
    try std.testing.expectEqual(revision + 1, retried.frame.revision);
    try std.testing.expectEqual(@as(usize, 1), retried.external.len);
    try std.testing.expectEqual(binding.resource, retried.external[0].resource);
    try std.testing.expectEqual(binding.resource, firstRgba(retried.frame.commands).?.resource.resource);
    try std.testing.expectError(error.InvalidImageBinding, terminal.updateObservation(host.renderer, owner.observation(), 0, &.{}));
    try std.testing.expectError(error.InvalidView, host.finishPresent());
}

test "terminal renderer canonical scalar bounds reject without truncation and recover" {
    var owner = try VT.init(std.testing.allocator, 1, 4);
    defer owner.deinit();
    try feedCanonical(&owner, "A");
    const font = try terminalFont();
    defer font.deinit();
    var host = try Harness.init(std.testing.allocator, font, rendererConfig(128));
    defer host.deinit();
    try terminal.updateObservation(host.renderer, owner.observation(), 0, &.{});
    const accepted = try host.finishPresent();
    try std.testing.expect(accepted.frame.revision != 0);
    try feedCanonical(&owner, "\ra\u{300}\u{301}\u{302}\u{303}\u{304}\u{305}\u{306}\u{307}");
    var scalars: [24]u21 = undefined;
    try std.testing.expectEqual(@as(usize, 9), owner.observation().semanticView(0).cellScalarsAt(0, 0, &scalars).len);
    try std.testing.expectError(error.ShapeSequenceLimit, terminal.updateObservation(host.renderer, owner.observation(), 0, &.{}));
    try std.testing.expectError(error.InvalidView, host.finishPresent());
    try feedCanonical(&owner, "\x1bcA");
    try terminal.updateObservation(host.renderer, owner.observation(), 0, &.{});
    const recovered = try host.finishPresent();
    try std.testing.expectEqual(@as(u64, 2), recovered.frame.revision);
}

test "terminal renderer canonical virtual placements and OSC 66 share final projection" {
    try expectDirectEquivalent("\x1b_Ga=t,f=32,s=1,v=1,i=56,q=2;/wAA/w==\x1b\\" ++
        "\x1b_Ga=p,i=56,c=1,r=1,U=1,q=2\x1b\\" ++
        "\x1b[38;5;56m\u{10eeee}\u{305}\u{305}\x1b[0m", 0);
    try expectDirectEquivalent("\x1b]66;s=2;AB\x07", 0);
}

test "terminal renderer space owns no glyph ink while presentation layers remain" {
    var scalar = [_]u32{' '};
    var cells = [_]client.rich.Cell{cell(&scalar, 1, 0)};
    cells[0].style_bits = 0;
    var rows = [_]client.rich.Row{.{ .wrapped = false, .line_geometry = 0, .cells = &cells }};
    var source = sourceSnapshot(&rows, 1);
    source.begin.terminal.cursor_visible = true;
    source.presentation.presence_bits = 1;
    source.presentation.cursor = .{ .r = 9, .g = 8, .b = 7, .a = 255 };
    const view = try client.view.project(std.testing.allocator, &source);
    defer client.view.deinit(view);
    const font = try terminalFont();
    defer font.deinit();
    var host = try Harness.init(std.testing.allocator, font, rendererConfig(32));
    defer host.deinit();
    const frame = (try host.present(view)).frame;

    var alpha_count: usize = 0;
    var cursor_background = false;
    for (frame.commands) |command| switch (command) {
        .alpha_mask => alpha_count += 1,
        .solid => |value| if (std.meta.eql(value.color, terminal.Color{ .r = 9, .g = 8, .b = 7, .a = 255 })) {
            cursor_background = true;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 0), alpha_count);
    try std.testing.expect(cursor_background);
}

test "terminal renderer styled space keeps background and decoration without glyph ink" {
    var scalar = [_]u32{' '};
    var cells = [_]client.rich.Cell{cell(&scalar, 1, 0)};
    cells[0].style_bits = (1 << 5) | (1 << 7) | (1 << 8);
    cells[0].underline_style = 1;
    cells[0].underline_color = .{ .kind = .rgb, .value = 0x445566 };
    var rows = [_]client.rich.Row{.{ .wrapped = false, .line_geometry = 0, .cells = &cells }};
    const source = sourceSnapshot(&rows, 1);
    const view = try client.view.project(std.testing.allocator, &source);
    defer client.view.deinit(view);
    const font = try terminalFont();
    defer font.deinit();
    var host = try Harness.init(std.testing.allocator, font, rendererConfig(32));
    defer host.deinit();
    const frame = (try host.present(view)).frame;

    var alpha_count: usize = 0;
    var reverse_background = false;
    var decoration_count: usize = 0;
    for (frame.commands) |command| switch (command) {
        .alpha_mask => alpha_count += 1,
        .solid => |value| {
            if (std.meta.eql(value.color, terminal.Color{ .r = 0xab, .g = 0xcd, .b = 0xef, .a = 255 }))
                reverse_background = true;
            if (std.meta.eql(value.color, terminal.Color{ .r = 0x44, .g = 0x55, .b = 0x66, .a = 255 }))
                decoration_count += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 0), alpha_count);
    try std.testing.expect(reverse_background);
    try std.testing.expect(decoration_count >= 1);
}

test "terminal renderer canonical singleton and mixed cluster cells equal rich and owned frames" {
    const cases = [_][]const u8{
        "  A B   ",
        "\x1b[7;4;9m \x1b[0m \x1b[6 q",
        " \u{301} A\u{301} B\u{301}\u{302}\u{303}\u{304}\u{305}",
        "\u{754c} A \x1b]66;s=2;B\x07",
        "\x1b#6A B \r\n\x1b#3C D\r\n\x1b#4C D",
        "A\u{301}\u{302}\u{303}\u{304}\u{305}\r\nB\r\n C\r\nD\r\nE\r\nF",
    };
    for (cases) |bytes| try expectDirectEquivalent(bytes, 0);
    try expectDirectEquivalent(cases[cases.len - 1], 2);
}
