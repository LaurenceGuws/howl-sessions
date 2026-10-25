//! Immutable Server observation envelope beside VT-owned terminal storage.
//! One allocation contains this private wrapper and the optional codec's packed
//! terminal region. Server delivery identity never enters the codec.
const std = @import("std");
const protocol = @import("server_protocol").terminal;
const rich = @import("rich.zig");
const codec = @import("howl_vt_codec");
const terminal_view = codec.view;

/// Allocation or malformed/bounded Server observation projection.
pub const Error = std.mem.Allocator.Error || error{ InvalidRichSnapshot, ViewTooLarge };
/// Server observation, lifecycle and authority envelope.
pub const Begin = protocol.SnapshotBegin;
/// Canonical terminal view Metadata.
pub const Metadata = terminal_view.Metadata;
/// Canonical terminal view Presentation.
pub const Presentation = terminal_view.Presentation;
/// Canonical terminal view TextColor.
pub const TextColor = terminal_view.TextColor;
/// Canonical terminal view Image.
pub const Image = terminal_view.Image;
/// Canonical terminal view ImagePlacement.
pub const ImagePlacement = terminal_view.ImagePlacement;
/// Canonical terminal view maximum_images.
pub const maximum_images = terminal_view.maximum_images;
/// Canonical terminal view maximum_image_placements.
pub const maximum_image_placements = terminal_view.maximum_image_placements;
/// Canonical terminal view CellStyle.
pub const CellStyle = terminal_view.CellStyle;
/// Canonical terminal view CursorShape.
pub const CursorShape = terminal_view.CursorShape;
/// Canonical terminal view LineGeometry.
pub const LineGeometry = terminal_view.LineGeometry;
/// Canonical terminal view Row.
pub const Row = terminal_view.Row;
/// Canonical terminal view Cell.
pub const Cell = terminal_view.Cell;
/// Canonical terminal view Hyperlink.
pub const Hyperlink = terminal_view.Hyperlink;
/// Canonical terminal view Graphics.
pub const Graphics = terminal_view.Graphics;
/// Canonical terminal view TextProjection.
pub const TextProjection = terminal_view.TextProjection;
/// Canonical terminal view cellStyleFromBits.
pub const cellStyleFromBits = terminal_view.cellStyleFromBits;
/// Canonical terminal view cellStyle.
pub const cellStyle = terminal_view.cellStyle;
/// Canonical terminal view cursorShapeFromValue.
pub const cursorShapeFromValue = terminal_view.cursorShapeFromValue;
/// Canonical terminal view lineGeometryFromValue.
pub const lineGeometryFromValue = terminal_view.lineGeometryFromValue;
/// Canonical terminal view lineGeometry.
pub const lineGeometry = terminal_view.lineGeometry;
/// Canonical terminal view isImagePlaceholder.
pub const isImagePlaceholder = terminal_view.isImagePlaceholder;

/// Opaque owner of one immutable Server observation.
// zig-audit: acknowledge opaque_type
// reason: The Server envelope and terminal-region ownership remain private to this single allocation.
pub const Snapshot = opaque {};
const Impl = struct {
    allocator: std.mem.Allocator,
    word_count: usize,
    begin: Begin,
    changed_rows_base_revision: ?u64,
    terminal: *const terminal_view.Snapshot,
};
const terminal_offset = std.mem.alignForward(usize, @sizeOf(Impl), terminal_view.storage_alignment);
comptime {
    if (@alignOf(Impl) > @alignOf(u128)) @compileError("Server view owner exceeds allocation alignment");
}

/// Copies an already-decoded Server observation into one immutable allocation.
pub fn project(allocator: std.mem.Allocator, source: *const rich.Snapshot) Error!*Snapshot {
    const borrowed = source.view();
    return projectView(allocator, &borrowed);
}

/// Copies a borrowed Server observation; the source may then be released.
pub fn projectView(allocator: std.mem.Allocator, source: *const rich.View) Error!*Snapshot {
    if (source.changed_rows == null and source.changed_rows_base_revision != null)
        return error.InvalidRichSnapshot;
    const terminal_source = terminalSource(source);
    const terminal_bytes = terminal_view.storageSize(&terminal_source) catch |failure| return projectionError(failure);
    const total_bytes = std.math.add(usize, terminal_offset, terminal_bytes) catch return error.ViewTooLarge;
    // zig-audit: acknowledge catch_unreachable
    // reason: @sizeOf(u128) is a fixed nonzero divisor, so divCeil cannot report division by zero.
    const word_count = std.math.divCeil(usize, total_bytes, @sizeOf(u128)) catch unreachable;
    const storage = try allocator.alloc(u128, word_count);
    errdefer allocator.free(storage);
    const bytes = std.mem.sliceAsBytes(storage);
    // zig-audit: acknowledge align_cast
    // reason: terminal_offset is aligned to codec storage alignment inside the original u128 allocation.
    const terminal_bytes_aligned: []align(terminal_view.storage_alignment) u8 = @alignCast(bytes[terminal_offset..]);
    const terminal = terminal_view.projectInto(terminal_bytes_aligned, &terminal_source) catch |failure| return projectionError(failure);
    // zig-audit: acknowledge ptr_cast
    // reason: The u128 allocation covers Impl and the aligned terminal region; Impl occupies byte zero.
    const impl: *Impl = @ptrCast(storage.ptr);
    impl.* = .{ .allocator = allocator, .word_count = word_count, .begin = source.begin, .changed_rows_base_revision = source.changed_rows_base_revision, .terminal = terminal };
    // zig-audit: acknowledge ptr_cast
    // reason: Snapshot is the opaque public owner for this exact Impl allocation and preserves its address.
    return @ptrCast(impl);
}

/// Releases the envelope and terminal region together; every borrowed slice expires.
pub fn deinit(snapshot: *Snapshot) void {
    const impl = constImpl(snapshot);
    const allocator = impl.allocator;
    const word_count = impl.word_count;
    // zig-audit: acknowledge ptr_cast
    // reason: Impl occupies byte zero of the original []u128 owner allocation.
    // zig-audit: acknowledge align_cast
    // reason: The original []u128 allocation provides the required storage alignment.
    const storage: [*]const u128 = @ptrCast(@alignCast(impl));
    allocator.free(storage[0..word_count]);
}

/// Borrows Server observation, lifecycle and authority facts.
pub fn begin(snapshot: *const Snapshot) *const Begin {
    return &constImpl(snapshot).begin;
}

/// Borrows the independently usable VT observation within this Server owner.
pub fn observation(snapshot: *const Snapshot) *const terminal_view.Snapshot {
    return constImpl(snapshot).terminal;
}

/// Canonical VT revision, history, viewport and cursor metadata.
pub fn metadata(snapshot: *const Snapshot) *const Metadata {
    return terminal_view.metadata(observation(snapshot));
}

/// Complete terminal colors, palette, cursor age and presentation flags.
pub fn presentation(snapshot: *const Snapshot) *const Presentation {
    return terminal_view.presentation(observation(snapshot));
}

/// Exact terminal properties, including absent and empty reports.
pub fn properties(snapshot: *const Snapshot) codec.properties.View {
    return terminal_view.properties(observation(snapshot));
}

/// The complete flattened terminal row array.
pub fn rows(snapshot: *const Snapshot) []const Row {
    return terminal_view.rows(observation(snapshot));
}

/// The complete flattened terminal cell array.
pub fn cells(snapshot: *const Snapshot) []const Cell {
    return terminal_view.cells(observation(snapshot));
}

/// The shared Unicode scalar bank.
pub fn scalars(snapshot: *const Snapshot) []const u32 {
    return terminal_view.scalars(observation(snapshot));
}

/// The validated terminal cursor shape.
pub fn cursorShape(snapshot: *const Snapshot) CursorShape {
    return terminal_view.cursorShape(observation(snapshot));
}

/// Hyperlink identities indexing the shared URI bank.
pub fn hyperlinks(snapshot: *const Snapshot) []const Hyperlink {
    return terminal_view.hyperlinks(observation(snapshot));
}

/// The exact hyperlink URI byte bank.
pub fn uris(snapshot: *const Snapshot) []const u8 {
    return terminal_view.uris(observation(snapshot));
}

/// Terminal resource identities, placements and cell-pixel lattice.
pub fn graphics(snapshot: *const Snapshot) Graphics {
    return terminal_view.graphics(observation(snapshot));
}

/// The decoded row-change mask, if present.
pub fn changedRows(snapshot: *const Snapshot) ?[]const bool {
    return terminal_view.changedRows(observation(snapshot));
}

/// The upward baseline rotation applied before row repair.
pub fn rowShift(snapshot: *const Snapshot) ?u16 {
    return terminal_view.rowShift(observation(snapshot));
}

/// Borrows one validated cell's Unicode scalars.
pub fn cellScalars(snapshot: *const Snapshot, cell: Cell) []const u32 {
    return terminal_view.cellScalars(observation(snapshot), cell);
}

/// Server observation revision against which changedRows was computed.
pub fn changedRowsBaseRevision(snapshot: *const Snapshot) ?u64 {
    return constImpl(snapshot).changed_rows_base_revision;
}

/// Writes bounded visible terminal text into caller storage.
pub fn writeVisibleText(snapshot: *const Snapshot, output: []u8) TextProjection {
    return terminal_view.writeVisibleText(observation(snapshot), output);
}

/// Writes canonical text and its scalar caret position into caller storage.
pub fn writeAccessibleText(snapshot: *const Snapshot, output: []u8) TextProjection {
    return terminal_view.writeAccessibleText(observation(snapshot), output);
}

/// Writes visible text from validated borrowed Server terminal facts.
pub fn writeVisibleRichText(snapshot: *const rich.View, output: []u8) TextProjection {
    const source = terminalSource(snapshot);
    return terminal_view.writeVisibleSourceText(&source, output);
}

fn terminalSource(source: *const rich.View) terminal_view.Source {
    return .{
        .metadata = &source.begin.terminal,
        .presentation = &source.presentation,
        .rows = source.rows,
        .hyperlinks = source.hyperlinks,
        .changed_rows = source.changed_rows,
        .row_shift = source.row_shift,
        .properties = source.properties,
        .graphics = .{
            .generation = source.graphics.generation,
            .content_generation = source.graphics.content_generation,
            .cell_pixel_width = source.graphics.cell_pixel_width,
            .cell_pixel_height = source.graphics.cell_pixel_height,
            .images = source.graphics.images,
            .placements = source.graphics.placements,
        },
    };
}

fn projectionError(failure: terminal_view.Error) Error {
    return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidSnapshot => error.InvalidRichSnapshot,
        error.ViewTooLarge, error.StorageTooSmall => error.ViewTooLarge,
    };
}

fn constImpl(snapshot: *const Snapshot) *const Impl {
    // zig-audit: acknowledge ptr_cast
    // reason: Every Snapshot is published from Impl at the same address by projectView.
    // zig-audit: acknowledge align_cast
    // reason: The original u128 owner allocation provides Impl alignment and the opaque handle preserves its address.
    return @ptrCast(@alignCast(snapshot));
}

fn testBegin(rows_count: u16, columns_count: u16) Begin {
    return .{
        .revision = 1,
        .terminal = .{
            .revision = 1,
            .history_offset = 0,
            .history_count = 0,
            .history_row_base = 0,
            .rows = rows_count,
            .columns = columns_count,
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
    };
}

fn testPresentation(palette: [256]rich.Rgba) Presentation {
    return .{
        .cursor_age_ns = null,
        .presence_bits = 0,
        .flags = 0,
        .reverse_screen = false,
        .palette = palette,
        .foreground = .{ .r = 0, .g = 0, .b = 0, .a = 0xff },
        .background = .{ .r = 0, .g = 0, .b = 0, .a = 0xff },
        .cursor = null,
        .cursor_text = null,
        .selection_background = null,
        .selection_foreground = null,
    };
}

fn testCell(scalar_values: []const u32) rich.Cell {
    return .{
        .scalars = scalar_values,
        .width = 1,
        .height = 1,
        .x = 0,
        .y = 0,
        .subscale_n = 1,
        .subscale_d = 1,
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

test "Server view owns its envelope beside one canonical terminal region" {
    var scalar_values = [_]u32{ 'e', 0x0301 };
    var source_cells = [_]rich.Cell{testCell(&scalar_values)};
    var source_rows = [_]rich.Row{.{ .wrapped = true, .line_geometry = 2, .cells = &source_cells }};
    const palette: [256]rich.Rgba = @splat(.{ .r = 0, .g = 0, .b = 0, .a = 0xff });
    var changed = [_]bool{true};
    var source = rich.View{
        .begin = testBegin(1, 1),
        .presentation = testPresentation(palette),
        .rows = &source_rows,
        .hyperlinks = &.{},
        .graphics = .{},
        .changed_rows = &changed,
        .changed_rows_base_revision = 99,
    };
    source.begin.revision = 100;
    source.begin.terminal.revision = 7;
    source.begin.leader_present = true;
    var fail_first = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, projectView(fail_first.allocator(), &source));
    try std.testing.expectEqual(@as(usize, 0), fail_first.allocations);
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const snapshot = try projectView(allocator.allocator(), &source);
    try std.testing.expectEqual(@as(usize, 1), allocator.allocations);
    const terminal = observation(snapshot);
    try std.testing.expectEqual(metadata(snapshot), terminal_view.metadata(terminal));
    try std.testing.expectEqual(rows(snapshot).ptr, terminal_view.rows(terminal).ptr);
    try std.testing.expectEqual(cells(snapshot).ptr, terminal_view.cells(terminal).ptr);
    try std.testing.expectEqual(scalars(snapshot).ptr, terminal_view.scalars(terminal).ptr);
    try std.testing.expectEqualDeep(begin(snapshot).terminal, metadata(snapshot).*);
    source.begin.revision = 101;
    source.begin.terminal.revision = 8;
    source.begin.leader_present = false;
    scalar_values[0] = 'X';
    source_rows[0].wrapped = false;
    changed[0] = false;
    try std.testing.expectEqual(@as(u64, 100), begin(snapshot).revision);
    try std.testing.expect(begin(snapshot).leader_present);
    try std.testing.expectEqual(@as(u64, 7), metadata(snapshot).revision);
    try std.testing.expectEqual(@as(?u64, 99), changedRowsBaseRevision(snapshot));
    try std.testing.expectEqualSlices(u32, &.{ 'e', 0x0301 }, terminal_view.scalars(terminal));
    try std.testing.expect(terminal_view.rows(terminal)[0].wrapped);
    try std.testing.expectEqualSlices(bool, &.{true}, terminal_view.changedRows(terminal).?);
    deinit(snapshot);
    try std.testing.expectEqual(@as(usize, 1), allocator.deallocations);
    try std.testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
}

test "coarse view owns exact incremental row hints" {
    var row_zero_cells = [_]rich.Cell{testCell(&.{'A'})};
    var row_one_cells = [_]rich.Cell{testCell(&.{'B'})};
    var rows_source = [_]rich.Row{
        .{ .wrapped = false, .line_geometry = 0, .cells = &row_zero_cells },
        .{ .wrapped = false, .line_geometry = 0, .cells = &row_one_cells },
    };
    var changed = [_]bool{ false, true };
    const palette: [256]rich.Rgba = @splat(.{ .r = 0, .g = 0, .b = 0, .a = 0xff });
    const source = rich.View{
        .begin = testBegin(2, 1),
        .presentation = testPresentation(palette),
        .rows = &rows_source,
        .hyperlinks = &.{},
        .graphics = .{},
        .changed_rows = &changed,
        .changed_rows_base_revision = 40,
        .row_shift = 1,
    };
    const snapshot = try projectView(std.testing.allocator, &source);
    defer deinit(snapshot);

    changed = .{ true, false };
    try std.testing.expectEqual(@as(?u16, 1), rowShift(snapshot));
    try std.testing.expectEqual(@as(?u64, 40), changedRowsBaseRevision(snapshot));
    try std.testing.expectEqualSlices(bool, &.{ false, true }, changedRows(snapshot).?);

    var same_index_source = source;
    same_index_source.row_shift = null;
    same_index_source.changed_rows = &changed;
    same_index_source.changed_rows_base_revision = 41;
    const same_index = try projectView(std.testing.allocator, &same_index_source);
    defer deinit(same_index);
    changed = .{ false, true };
    try std.testing.expectEqual(@as(?u16, null), rowShift(same_index));
    try std.testing.expectEqual(@as(?u64, 41), changedRowsBaseRevision(same_index));
    try std.testing.expectEqualSlices(bool, &.{ true, false }, changedRows(same_index).?);

    var malformed = source;
    malformed.changed_rows = changed[0..1];
    try std.testing.expectError(
        error.InvalidRichSnapshot,
        projectView(std.testing.allocator, &malformed),
    );
    malformed = source;
    malformed.changed_rows = null;
    try std.testing.expectError(
        error.InvalidRichSnapshot,
        projectView(std.testing.allocator, &malformed),
    );
}
