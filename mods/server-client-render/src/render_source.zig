//! Adapts Server terminal-client semantic views to the terminal renderer source contract.
//!
//! This file owns storage/lifetime adaptation only. It does not render, shape,
//! rasterize, retain backend resources, or interpret terminal protocol bytes.

const std = @import("std");
const client = @import("terminal_client");
const semantic = @import("howl_render").adapter;
const View = client.view;
const Rich = client.rich;

fn style(style_bits: u16) semantic.CellStyle {
    const value = View.cellStyleFromBits(style_bits);
    return .{
        .bold = value.bold,
        .dim = value.dim,
        .italic = value.italic,
        .reverse = value.reverse,
        .invisible = value.invisible,
        .underline = value.underline,
        .strikethrough = value.strikethrough,
    };
}

fn color(value: View.TextColor) semantic.TextColor {
    return .{
        .kind = switch (value.kind) {
            .default => .default,
            .indexed => .indexed,
            .rgb => .rgb,
        },
        .value = value.value,
    };
}

fn image(value: View.Image) semantic.Image {
    return .{
        .image_id = value.image_id,
        .generation = value.generation,
        .width = value.width,
        .height = value.height,
    };
}

fn placement(value: View.ImagePlacement) semantic.ImagePlacement {
    return .{
        .image_id = value.image_id,
        .generation = value.generation,
        .row = value.row,
        .column = value.column,
        .source_x = value.source_x,
        .source_y = value.source_y,
        .source_width = value.source_width,
        .source_height = value.source_height,
        .cell_x = value.cell_x,
        .cell_y = value.cell_y,
        .pixel_width = value.pixel_width,
        .pixel_height = value.pixel_height,
        .z = value.z,
    };
}

fn normalizeLineGeometry(value: View.LineGeometry) semantic.LineGeometry {
    return switch (value) {
        .single_width => .single_width,
        .double_width => .double_width,
        .double_height_top => .double_height_top,
        .double_height_bottom => .double_height_bottom,
    };
}

fn cursorShapeValue(value: View.CursorShape) semantic.CursorShape {
    return switch (value) {
        .block => .block,
        .underline => .underline,
        .bar => .bar,
        .none => .none,
    };
}

const OwnedStorage = struct {
    const Snapshot = View.Snapshot;
    const Row = View.Row;
    const Cell = View.Cell;

    fn begin(snapshot: *const Snapshot) *const View.Begin {
        return View.begin(snapshot);
    }

    fn metadata(snapshot: *const Snapshot) *const View.Metadata {
        return View.metadata(snapshot);
    }

    fn presentation(snapshot: *const Snapshot) *const View.Presentation {
        return View.presentation(snapshot);
    }

    fn rowRecords(snapshot: *const Snapshot) []const Row {
        return View.rows(snapshot);
    }

    fn rowCellCount(row: Row) usize {
        return row.cell_count;
    }

    fn cellAt(snapshot: *const Snapshot, row: Row, column: usize) Cell {
        const all = View.cells(snapshot);
        const first: usize = row.cell_offset;
        const count: usize = row.cell_count;
        std.debug.assert(first <= all.len and count <= all.len - first);
        std.debug.assert(column < count);
        return all[first + column];
    }

    fn cellScalars(snapshot: *const Snapshot, cell: Cell) []const u32 {
        return View.cellScalars(snapshot, cell);
    }

    fn graphics(snapshot: *const Snapshot) View.Graphics {
        return View.graphics(snapshot);
    }

    fn changedRowsBaseRevision(snapshot: *const Snapshot) ?u64 {
        return View.changedRowsBaseRevision(snapshot);
    }

    fn changedRows(snapshot: *const Snapshot) ?[]const bool {
        return View.changedRows(snapshot);
    }

    fn rowShift(snapshot: *const Snapshot) ?u16 {
        return View.rowShift(snapshot);
    }

    fn lineGeometry(row: Row) View.LineGeometry {
        return View.lineGeometry(row);
    }
};

const RichStorage = struct {
    const Snapshot = Rich.View;
    const Row = Rich.Row;
    const Cell = Rich.Cell;

    fn begin(snapshot: *const Snapshot) *const View.Begin {
        return &snapshot.begin;
    }

    fn metadata(snapshot: *const Snapshot) *const View.Metadata {
        return &snapshot.begin.terminal;
    }

    fn presentation(snapshot: *const Snapshot) *const View.Presentation {
        return &snapshot.presentation;
    }

    fn rowRecords(snapshot: *const Snapshot) []const Row {
        return snapshot.rows;
    }

    fn rowCellCount(row: Row) usize {
        return row.cells.len;
    }

    fn cellAt(_: *const Snapshot, row: Row, column: usize) Cell {
        std.debug.assert(column < row.cells.len);
        return row.cells[column];
    }

    fn cellScalars(_: *const Snapshot, cell: Cell) []const u32 {
        return cell.scalars;
    }

    fn graphics(snapshot: *const Snapshot) View.Graphics {
        return .{
            .generation = snapshot.graphics.generation,
            .content_generation = snapshot.graphics.content_generation,
            .cell_pixel_width = snapshot.graphics.cell_pixel_width,
            .cell_pixel_height = snapshot.graphics.cell_pixel_height,
            .images = snapshot.graphics.images,
            .placements = snapshot.graphics.placements,
        };
    }

    fn changedRowsBaseRevision(snapshot: *const Snapshot) ?u64 {
        return snapshot.changed_rows_base_revision;
    }

    fn changedRows(snapshot: *const Snapshot) ?[]const bool {
        return snapshot.changed_rows;
    }

    fn rowShift(snapshot: *const Snapshot) ?u16 {
        return snapshot.row_shift;
    }

    fn lineGeometry(row: Row) View.LineGeometry {
        return View.lineGeometryFromValue(row.line_geometry);
    }
};

fn ClientSource(comptime Storage: type) type {
    return struct {
        /// Exact snapshot storage consumed synchronously by this adapter specialization.
        pub const Snapshot = Storage.Snapshot;
        /// One source row record in the selected client storage representation.
        pub const Row = Storage.Row;
        /// One source cell record in the selected client storage representation.
        pub const Cell = Storage.Cell;
        /// Client storage already returns complete values and needs no fallback scratch.
        pub const CellScratch = struct {};
        /// Complete decoded terminal presentation retained by the selected client view.
        pub const Presentation = View.Presentation;
        /// Four-channel presentation color shared by owned and borrowed client views.
        pub const PresentationColor = Rich.Rgba;
        /// Borrowed transported graphics manifest shared by both client storage forms.
        pub const Graphics = View.Graphics;
        /// Client observations may carry exact revision-relative changed-row facts.
        pub const supports_incremental = true;

        /// Returns the declared visible terminal row count.
        pub fn rows(snapshot: *const Snapshot) u16 {
            return Storage.metadata(snapshot).rows;
        }

        /// Returns the declared physical terminal column count.
        pub fn columns(snapshot: *const Snapshot) u16 {
            return Storage.metadata(snapshot).columns;
        }

        /// Returns the canonical cursor row in the current client view.
        pub fn cursorRow(snapshot: *const Snapshot) u16 {
            return Storage.metadata(snapshot).cursor_row;
        }

        /// Returns the canonical cursor column in the current client view.
        pub fn cursorColumn(snapshot: *const Snapshot) u16 {
            return Storage.metadata(snapshot).cursor_column;
        }

        /// Reports canonical cursor visibility before renderer surface clipping.
        pub fn cursorVisible(snapshot: *const Snapshot) bool {
            return Storage.metadata(snapshot).cursor_visible;
        }

        /// Returns the client-selected retained-history offset for incremental identity.
        pub fn historyOffset(snapshot: *const Snapshot) u32 {
            return Storage.metadata(snapshot).history_offset;
        }

        /// Reports which canonical screen bank this observation represents.
        pub fn alternateScreen(snapshot: *const Snapshot) bool {
            return Storage.metadata(snapshot).alternate_screen;
        }

        /// Borrows the decoded presentation state from the selected client storage.
        pub fn presentation(snapshot: *const Snapshot) *const View.Presentation {
            return Storage.presentation(snapshot);
        }

        /// Returns the number of physically exposed row records for geometry validation.
        pub fn rowCount(snapshot: *const Snapshot) usize {
            return Storage.rowRecords(snapshot).len;
        }

        /// Returns one dense row record by validated source index.
        pub fn rowAt(snapshot: *const Snapshot, index: usize) Row {
            return Storage.rowRecords(snapshot)[index];
        }

        /// Returns the number of physically exposed cells in one row record.
        pub fn rowCellCount(_: *const Snapshot, row: Row) usize {
            return Storage.rowCellCount(row);
        }

        /// Copies one cell from the selected client storage representation.
        pub fn cellAt(snapshot: *const Snapshot, row: Row, column: usize, _: *CellScratch) Cell {
            return Storage.cellAt(snapshot, row, column);
        }

        /// Borrows the complete scalar cluster already owned by client storage.
        pub fn cellScalars(
            snapshot: *const Snapshot,
            _: usize,
            _: usize,
            cell: Cell,
            _: *[24]u32,
        ) []const u32 {
            return Storage.cellScalars(snapshot, cell);
        }

        /// Copies only rendition bits that directly affect this untimed frame projection.
        pub fn cellStyle(cell: Cell) semantic.CellStyle {
            return style(cell.style_bits);
        }

        /// Returns the terminal font slot independently of client storage layout.
        pub fn cellFont(cell: Cell) u8 {
            return cell.font;
        }

        /// Returns the normalized baseline selector retained by the client view.
        pub fn cellBaseline(cell: Cell) u8 {
            return cell.baseline;
        }

        /// Returns the normalized underline style retained by the client view.
        pub fn cellUnderlineStyle(cell: Cell) u8 {
            return cell.underline_style;
        }

        /// Normalizes one requested cell color role without leaking client protocol types.
        pub fn cellColor(cell: Cell, role: semantic.ColorRole) semantic.TextColor {
            return color(switch (role) {
                .foreground => cell.foreground,
                .background => cell.background,
                .underline_color => cell.underline_color,
            });
        }

        /// Recognizes Kitty's reserved Unicode placement scalar through client semantics.
        pub fn isImagePlaceholder(
            _: *const Snapshot,
            _: usize,
            _: usize,
            sequence: []const u32,
        ) bool {
            return View.isImagePlaceholder(sequence);
        }

        /// Copies the client graphics manifest into one common borrowed view shape.
        pub fn graphics(snapshot: *const Snapshot) View.Graphics {
            return Storage.graphics(snapshot);
        }

        /// Returns the exact observation revision published by this client view.
        pub fn observationRevision(snapshot: *const Snapshot) u64 {
            return Storage.begin(snapshot).revision;
        }

        /// Returns the predecessor revision used to derive changed-row facts, when any.
        pub fn changedRowsBaseRevision(snapshot: *const Snapshot) ?u64 {
            return Storage.changedRowsBaseRevision(snapshot);
        }

        /// Borrows the exact changed-row repair mask, when the observation provides one.
        pub fn changedRows(snapshot: *const Snapshot) ?[]const bool {
            return Storage.changedRows(snapshot);
        }

        /// Returns the upward baseline row rotation preceding changed-row repairs.
        pub fn rowShift(snapshot: *const Snapshot) ?u16 {
            return Storage.rowShift(snapshot);
        }

        /// Normalizes one client DEC line-geometry value into renderer-private semantics.
        pub fn lineGeometry(_: *const Snapshot, row: Row) semantic.LineGeometry {
            return normalizeLineGeometry(Storage.lineGeometry(row));
        }

        /// Normalizes canonical cursor geometry without carrying client enum identity.
        pub fn cursorShape(snapshot: *const Snapshot) semantic.CursorShape {
            return cursorShapeValue(View.cursorShapeFromValue(Storage.metadata(snapshot).cursor_shape));
        }

        /// Returns every image record in the transported visible manifest.
        pub fn graphicsImageCount(state: View.Graphics) usize {
            return state.images.len;
        }

        /// Normalizes one transported image manifest entry.
        pub fn graphicsImage(state: View.Graphics, index: usize) semantic.Image {
            return image(state.images[index]);
        }

        /// Returns every placement record in the transported visible manifest.
        pub fn graphicsPlacementCount(state: View.Graphics) usize {
            return state.placements.len;
        }

        /// Normalizes one transported image placement.
        pub fn graphicsPlacement(state: View.Graphics, index: usize) ?semantic.ImagePlacement {
            return placement(state.placements[index]);
        }

        /// Transported manifests contain only images referenced by this observation.
        pub fn graphicsImageVisible(_: View.Graphics, _: u32) bool {
            return true;
        }
    };
}

/// Adapts one independently owned immutable Server terminal-client view.
pub const Owned = ClientSource(OwnedStorage);
/// Adapts one already-validated borrowed Server terminal-client rich view.
pub const RichView = ClientSource(RichStorage);
