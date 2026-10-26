//! Encoding specialized on the canonical VT's existing borrowed observation.
const std = @import("std");
const protocol = @import("wire.zig");
const values = @import("decoded.zig");
const facts = @import("metadata.zig");

/// Allocation failure or a text body exceeding the codec bound.
pub const AppendError = std.mem.Allocator.Error || error{SnapshotTooLarge};

/// Fixed link identities referenced by one text cut or retained delta row.
pub const link_word_count = (protocol.text_v1.maximum_hyperlinks + 1 + 63) / 64;
/// Bounded link membership, independent of Server observation identity.
pub const Links = [link_word_count]u64;

/// Notes a terminal link identity in a caller-owned bounded membership set.
pub fn noteLink(link_id: u32, links: []u64) error{InvalidSnapshot}!void {
    if (links.len != link_word_count or link_id > protocol.text_v1.maximum_hyperlinks)
        return error.InvalidSnapshot;
    if (link_id == 0) return;
    const index: usize = @intCast(link_id);
    const shift: u6 = @intCast(index % 64);
    links[index / 64] |= @as(u64, 1) << shift;
}

/// Merges bounded row memberships into the current text observation.
pub fn mergeLinks(links: *Links, row_links: []const u64) void {
    std.debug.assert(row_links.len == link_word_count);
    for (links, row_links) |*destination, source| destination.* |= source;
}

/// Appends the exact codec delta rotation record, without choosing its baseline.
pub fn appendRowShift(allocator: std.mem.Allocator, output: *std.ArrayList(u8), shift: u16) AppendError!void {
    const start = output.items.len;
    errdefer output.shrinkRetainingCapacity(start);
    const record = try beginTextRecord(allocator, output, .row_shift);
    var payload: [protocol.text_delta_v2.row_shift_bytes]u8 = undefined;
    protocol.encodeTextRowShift(&payload, shift);
    try output.appendSlice(allocator, &payload);
    try finishTextRecord(output, record);
}

/// Appends the explicit delta marker for a row retained by a named baseline.
pub fn appendRowReuse(allocator: std.mem.Allocator, output: *std.ArrayList(u8)) AppendError!void {
    var header: [protocol.text_v1.record_header_bytes]u8 = undefined;
    protocol.encodeTextRecordHeader(&header, .{ .kind = .row, .payload_len = 0 });
    if (output.items.len > protocol.maximum_text_snapshot_bytes - header.len)
        return error.SnapshotTooLarge;
    try output.appendSlice(allocator, &header);
}

/// Specializes encoding on the canonical read-only Observation interface.
/// No parser is imported by this module. Callers select their exact observation
/// type; every value remains a synchronous borrow, and encoding never progresses
/// or publishes canonical state.
pub fn Encoder(comptime Observation: type) type {
    return struct {
        const SemanticView = @TypeOf(@as(*const Observation, undefined).semanticView(0));
        const Cell = @TypeOf(@as(SemanticView, undefined).cellInfoAt(0, 0));
        const LineGeometry = @TypeOf(@as(SemanticView, undefined).lineGeometry(0));
        const Presentation = @TypeOf(@as(*const Observation, undefined).presentation());
        const Images = @TypeOf(@as(*const Observation, undefined).images(0));

        const Encoding = @This();

        /// Optional retained terminal rows; no Server revision or delivery policy.
        pub const DeltaCache = struct {
            const Entry = struct {
                generation: ?u64 = null,
                wrapped: bool = false,
                geometry: LineGeometry = .single_width,
                valid: bool = false,
            };

            // Live views use row generations and retain no cell mirror. Historical
            // windows lack row provenance, so they keep the previous exact-cell fallback.
            cells: []Cell = &.{},
            entries: []Entry = &.{},
            links: []u64 = &.{},
            row_count: u16 = 0,
            column_count: u16 = 0,
            history_offset: u32 = 0,
            complete: bool = false,
            alternate_screen: bool = false,
            row_origin: ?u64 = null,

            /// Releases retained row provenance, historical cell mirrors and link sets.
            pub fn deinit(self: *DeltaCache, allocator: std.mem.Allocator) void {
                self.clear(allocator);
                self.* = undefined;
            }

            fn clear(self: *DeltaCache, allocator: std.mem.Allocator) void {
                if (self.links.len != 0) allocator.free(self.links);
                if (self.entries.len != 0) allocator.free(self.entries);
                if (self.cells.len != 0) allocator.free(self.cells);
                self.* = .{};
            }

            /// Revokes every row-reuse right after encoding or downstream delivery failure.
            pub fn invalidate(self: *DeltaCache) void {
                for (self.entries) |*entry| entry.valid = false;
                self.complete = false;
                self.row_origin = null;
            }

            /// A complete body or an explicit delta body using the authorized predecessor.
            pub const Mode = enum { full, delta };

            /// Appends a terminal cut, retaining live row generations or exact history cells.
            /// One cache belongs to one stable Observation owner. The caller authorizes
            /// delivery identity independently through allow_reuse.
            /// On every failure, the output prefix survives and all cached facts invalidate.
            /// Successful encoding is provisional: downstream failure must invalidate it.
            pub fn appendText(
                self: *DeltaCache,
                allocator: std.mem.Allocator,
                output: *std.ArrayList(u8),
                machine: *const Observation,
                history_offset: u32,
                cursor_age_ns: u64,
                allow_reuse: bool,
            ) values.Error!Mode {
                const start = output.items.len;
                errdefer output.shrinkRetainingCapacity(start);
                errdefer self.invalidate();
                const view = machine.semanticView(history_offset);
                try self.ensure(allocator, view.rows, view.cols, view.history_offset);
                // Numeric row generations are local to their screen bank.
                if (self.alternate_screen != view.is_alternate_screen) self.invalidate();
                const mode: Mode = if (allow_reuse and self.complete) .delta else .full;
                const current_row_origin: ?u64 = if (view.is_alternate_screen or
                    view.history_offset > view.history_count)
                    null
                else
                    @as(u64, view.history_row_base) + view.history_count - view.history_offset;
                const shifted_rows: ?u16 = if (mode == .delta and
                    self.row_origin != null and current_row_origin != null and
                    current_row_origin.? > self.row_origin.?)
                blk: {
                    const distance = current_row_origin.? - self.row_origin.?;
                    if (distance >= view.rows) break :blk null;
                    break :blk std.math.cast(u16, distance);
                } else null;
                var referenced_links: Links = @splat(0);
                try Encoding.appendPresentation(allocator, machine, output, cursor_age_ns);
                if (mode == .delta) try appendRowShift(allocator, output, shifted_rows orelse 0);

                // Upward rotation reads later source rows before earlier destinations
                // overwrite them. No second provenance or historical cell bank is needed.
                var row: u16 = 0;
                while (row < view.rows) : (row += 1) {
                    const wrapped = view.rowWrapped(row);
                    const geometry = view.lineGeometry(row);
                    const destination_cache = &self.entries[row];
                    const exact_mirror = self.cells.len != 0;
                    const generation = if (!exact_mirror) view.rowGeneration(row) else null;
                    const destination_cells: []Cell = if (exact_mirror)
                        self.rowCells(row, view.cols)
                    else
                        &.{};
                    const source_row: ?u16 = if (shifted_rows) |shift| blk: {
                        const shifted = std.math.add(u16, row, shift) catch break :blk null;
                        if (shifted >= view.rows) break :blk null;
                        break :blk shifted;
                    } else row;
                    const source_cache: ?*const Entry = if (source_row) |source|
                        &self.entries[source]
                    else
                        null;
                    const source_cells: []const Cell = if (exact_mirror) blk: {
                        const source = source_row orelse break :blk &.{};
                        break :blk self.rowCells(source, view.cols);
                    } else &.{};
                    const destination_links = self.rowLinks(row);
                    const source_links: []const u64 = if (source_row) |source|
                        self.rowLinks(source)
                    else
                        &.{};
                    const reusable = if (source_cache) |value|
                        mode == .delta and value.valid and
                            value.wrapped == wrapped and value.geometry == geometry and
                            if (exact_mirror)
                                rowExactlyReusable(view, row, source_cells)
                            else
                                generation != null and value.generation != null and
                                    generation.? == value.generation.?
                    else
                        false;
                    if (reusable) {
                        if (source_row.? != row) @memcpy(destination_links, source_links);
                        mergeLinks(&referenced_links, destination_links);
                        try appendRowReuse(allocator, output);
                    } else {
                        @memset(destination_links, 0);
                        try Encoding.appendRow(allocator, output, view, row, destination_links);
                        mergeLinks(&referenced_links, destination_links);
                    }
                    if (exact_mirror) {
                        var column: u16 = 0;
                        while (column < view.cols) : (column += 1)
                            destination_cells[column] = view.cellInfoAt(row, column);
                    }
                    destination_cache.* = .{
                        .generation = generation,
                        .wrapped = wrapped,
                        .geometry = geometry,
                        .valid = true,
                    };
                }
                try Encoding.appendHyperlinks(allocator, output, machine, &referenced_links);
                self.complete = true;
                self.alternate_screen = view.is_alternate_screen;
                self.row_origin = current_row_origin;
                return mode;
            }

            fn rowExactlyReusable(view: SemanticView, row: u16, cached: []const Cell) bool {
                if (cached.len != view.cols) return false;
                for (cached, 0..) |before, column| {
                    const now = view.cellInfoAt(row, @intCast(column));
                    // Long clusters use a VT sidecar. Re-encode those rows rather than
                    // retaining a parallel scalar bank with stale sidecar identities.
                    if (now.combining_len > now.combining.len or
                        before.combining_len > before.combining.len or
                        !std.meta.eql(now, before))
                        return false;
                }
                return true;
            }

            fn ensure(
                self: *DeltaCache,
                allocator: std.mem.Allocator,
                rows: u16,
                columns: u16,
                history_offset: u32,
            ) AppendError!void {
                const retained_word_count = std.math.mul(usize, rows, link_word_count) catch
                    return error.SnapshotTooLarge;
                if (self.row_count == rows and self.column_count == columns and
                    self.history_offset == history_offset and self.entries.len == rows and
                    self.links.len == retained_word_count)
                    return;
                self.clear(allocator);
                const cell_count = std.math.mul(usize, rows, columns) catch
                    return error.SnapshotTooLarge;
                if (cell_count == 0 or cell_count > protocol.maximum_text_snapshot_bytes / protocol.text_v1.cell_header_bytes)
                    return error.SnapshotTooLarge;
                if (history_offset != 0) {
                    self.cells = try allocator.alloc(Cell, cell_count);
                    errdefer {
                        allocator.free(self.cells);
                        self.cells = &.{};
                    }
                }
                self.entries = try allocator.alloc(Entry, rows);
                errdefer {
                    allocator.free(self.entries);
                    self.entries = &.{};
                }
                self.links = try allocator.alloc(u64, retained_word_count);
                errdefer {
                    allocator.free(self.links);
                    self.links = &.{};
                }
                @memset(self.links, 0);
                for (self.entries) |*entry| entry.* = .{};
                self.row_count = rows;
                self.column_count = columns;
                self.history_offset = history_offset;
            }

            fn rowCells(self: *DeltaCache, row: u16, columns: u16) []Cell {
                // Retained row generations describe the current viewport only.
                // Historical cuts use explicit cells; callers must not borrow
                // live delta storage across geometry or history changes.
                std.debug.assert(row < self.row_count);
                std.debug.assert(columns == self.column_count);
                std.debug.assert(self.history_offset != 0 and self.cells.len != 0);
                const start = @as(usize, row) * columns;
                std.debug.assert(start + columns <= self.cells.len);
                return self.cells[start .. start + columns];
            }

            fn rowLinks(self: *DeltaCache, row: u16) []u64 {
                std.debug.assert(row < self.row_count);
                const start = @as(usize, row) * link_word_count;
                std.debug.assert(start + link_word_count <= self.links.len);
                return self.links[start .. start + link_word_count];
            }
        };

        /// Captures terminal facts from the same synchronous semantic viewport cut.
        pub fn metadata(view: SemanticView, revision: u64) facts.Metadata {
            return .{
                .revision = revision,
                .history_offset = view.history_offset,
                .history_count = view.history_count,
                .history_row_base = view.history_row_base,
                .rows = view.rows,
                .columns = view.cols,
                .cursor_row = view.cursor_row,
                .cursor_column = view.cursor_col,
                .cursor_shape = @intCast(@backingInt(view.cursor_shape)),
                .cursor_visible = view.cursor_visible,
                .cursor_blink = view.cursor_blink,
                .alternate_screen = view.is_alternate_screen,
            };
        }

        /// Appends one complete text cut; failures restore the caller's prefix.
        pub fn appendText(
            allocator: std.mem.Allocator,
            output: *std.ArrayList(u8),
            machine: *const Observation,
            history_offset: u32,
            cursor_age_ns: u64,
        ) values.Error!values.Geometry {
            const start = output.items.len;
            errdefer output.shrinkRetainingCapacity(start);
            const view = machine.semanticView(history_offset);
            var links: Links = @splat(0);
            try appendPresentation(allocator, machine, output, cursor_age_ns);
            var row: u16 = 0;
            while (row < view.rows) : (row += 1)
                try appendRow(allocator, output, view, row, &links);
            try appendHyperlinks(allocator, output, machine, &links);
            return .{ .rows = view.rows, .columns = view.cols };
        }

        /// Appends one exact VT row. Failure restores output and link membership.
        pub fn appendRow(
            allocator: std.mem.Allocator,
            output: *std.ArrayList(u8),
            view: SemanticView,
            row: u16,
            links: []u64,
        ) values.Error!void {
            if (row >= view.rows or links.len != link_word_count) return error.InvalidSnapshot;
            const start = output.items.len;
            errdefer output.shrinkRetainingCapacity(start);
            var before: Links = undefined;
            @memcpy(&before, links);
            errdefer @memcpy(links, &before);
            const record = try beginTextRecord(allocator, output, .row);
            const row_header: [protocol.text_v1.row_header_bytes]u8 = .{
                @intFromBool(view.rowWrapped(row)),
                richLineGeometry(view.lineGeometry(row)),
                @truncate(view.cols >> 8),
                @truncate(view.cols),
            };
            try output.appendSlice(allocator, &row_header);
            var column: u16 = 0;
            while (column < view.cols) : (column += 1) {
                const cell = view.cellInfoAt(row, column);
                try noteLink(cell.attrs.link_id, links);
                var scalar_storage: [protocol.text_v1.maximum_cell_scalars]u21 = undefined;
                const scalars: []const u21 = if (cell.codepoint != 0 and cell.x == 0 and cell.y == 0)
                    view.cellScalarsAt(row, column, &scalar_storage)
                else
                    &.{};
                if (scalars.len > protocol.text_v1.maximum_cell_scalars) return error.InvalidSnapshot;
                if (cell.codepoint != 0 and cell.x == 0 and cell.y == 0) {
                    if (scalars.len == 0 or scalars[0] != cell.codepoint) return error.InvalidSnapshot;
                } else if (scalars.len != 0) return error.InvalidSnapshot;
                try appendCell(allocator, output, cell, scalars);
                if (output.items.len > protocol.maximum_text_snapshot_bytes) return error.SnapshotTooLarge;
            }
            try finishTextRecord(output, record);
        }

        /// Appends exactly the referenced URI bytes; failure restores the prefix.
        pub fn appendHyperlinks(
            allocator: std.mem.Allocator,
            output: *std.ArrayList(u8),
            machine: *const Observation,
            links: *const Links,
        ) values.Error!void {
            if (links[0] & 1 != 0 or links[link_word_count - 1] & ~@as(u64, 1) != 0)
                return error.InvalidSnapshot;
            const start = output.items.len;
            errdefer output.shrinkRetainingCapacity(start);
            for (links, 0..) |initial_word, word_index| {
                var word = initial_word;
                while (word != 0) {
                    const bit: usize = @intCast(@ctz(word));
                    word &= word - 1;
                    const link_id = word_index * 64 + bit;
                    const uri = machine.hyperlinkUri(@intCast(link_id)) orelse return error.InvalidSnapshot;
                    if (uri.len == 0 or uri.len > protocol.text_v1.maximum_hyperlink_uri_bytes)
                        return error.InvalidSnapshot;
                    const record = try beginTextRecord(allocator, output, .hyperlink);
                    var header: [protocol.text_v1.hyperlink_header_bytes]u8 = undefined;
                    encodeU32(header[0..4], @intCast(link_id));
                    header[4] = @truncate(uri.len >> 8);
                    header[5] = @truncate(uri.len);
                    try output.appendSlice(allocator, &header);
                    try output.appendSlice(allocator, uri);
                    try finishTextRecord(output, record);
                }
            }
        }

        /// Appends VT colors and palette; input is a synchronous read-only borrow.
        pub fn appendPresentation(
            allocator: std.mem.Allocator,
            machine: *const Observation,
            output: *std.ArrayList(u8),
            cursor_age_ns: u64,
        ) values.Error!void {
            const start = output.items.len;
            errdefer output.shrinkRetainingCapacity(start);
            const record = try beginTextRecord(allocator, output, .presentation);
            const payload_start = output.items.len;
            const presentation = machine.presentation();
            var fixed: [12]u8 = @splat(0);
            encodeU64(fixed[0..8], cursor_age_ns);
            if (presentation.cursor != null)
                fixed[8] |= protocol.text_v1.presentation_presence.cursor;
            if (presentation.cursor_text != null)
                fixed[8] |= protocol.text_v1.presentation_presence.cursor_text;
            if (presentation.selection_background != null)
                fixed[8] |= protocol.text_v1.presentation_presence.selection_background;
            if (presentation.selection_foreground != null)
                fixed[8] |= protocol.text_v1.presentation_presence.selection_foreground;
            if (presentation.reverse_screen)
                fixed[9] |= protocol.text_v1.presentation_flags.reverse_screen;
            try output.appendSlice(allocator, &fixed);
            for (presentation.palette) |rgb| try appendRgba(allocator, output, rgb);
            try appendRgba(allocator, output, presentation.foreground);
            try appendRgba(allocator, output, presentation.background);
            try appendOptionalRgba(allocator, output, presentation.cursor);
            try appendOptionalRgba(allocator, output, presentation.cursor_text);
            try appendOptionalRgba(allocator, output, presentation.selection_background);
            try appendOptionalRgba(allocator, output, presentation.selection_foreground);
            if (output.items.len - payload_start != protocol.text_v1.presentation_bytes)
                return error.InvalidSnapshot;
            try finishTextRecord(output, record);
        }

        fn appendCell(
            allocator: std.mem.Allocator,
            output: *std.ArrayList(u8),
            cell: Cell,
            scalars: []const u21,
        ) !void {
            var encoded: [protocol.text_v1.cell_header_bytes]u8 = @splat(0);
            encoded[0] = @intCast(scalars.len);
            encoded[1] = cell.width;
            encoded[2] = cell.height;
            encoded[3] = cell.x;
            encoded[4] = cell.y;
            encoded[5] = cell.subscale_n;
            encoded[6] = cell.subscale_d;
            encoded[7] = cell.vertical_align;
            encoded[8] = cell.horizontal_align;
            encoded[9] = @intFromBool(cell.semantic_width);
            encoded[10] = cell.attrs.font;
            encoded[11] = richBaseline(cell.attrs.baseline);
            encoded[12] = richUnderlineStyle(cell.attrs.underline_style);
            encoded[13] = richProtection(cell.attrs.protected);
            const style = richStyle(cell.attrs);
            encoded[14] = @truncate(style >> 8);
            encoded[15] = @truncate(style);
            try encodeRichColor(encoded[16..21], cell.attrs.fg);
            try encodeRichColor(encoded[21..26], cell.attrs.bg);
            try encodeRichColor(encoded[26..31], cell.attrs.underline_color);
            encodeU32(encoded[31..35], cell.attrs.link_id);
            try output.appendSlice(allocator, &encoded);
            for (scalars) |scalar| {
                var scalar_bytes: [4]u8 = undefined;
                encodeU32(&scalar_bytes, scalar);
                try output.appendSlice(allocator, &scalar_bytes);
            }
        }

        /// Borrows the coherent terminal properties until canonical VT state advances.
        pub fn properties(machine: *const Observation) protocol.properties.View {
            const directory = machine.workingDirectory();
            const shell = machine.shellIntegration();
            const mark = machine.shellMark();
            const progress = machine.taskProgress();
            return .{
                .title = machine.title(),
                .icon = machine.icon(),
                .directory = if (directory) |value| .{
                    .kind = switch (value.kind) {
                        .uri => .uri,
                        .path => .path,
                    },
                    .value = value.value,
                } else null,
                .remote_host = machine.remoteHost(),
                .shell = if (shell) |value| .{ .version = value.version, .name = value.shell } else null,
                .mark = .{
                    .generation = mark.generation,
                    .kind = mark.kind,
                    .status = mark.status,
                    .metadata = mark.metadata,
                },
                .progress = .{
                    .kind = switch (progress.kind) {
                        .none => .none,
                        .normal => .normal,
                        .failure => .failure,
                        .indeterminate => .indeterminate,
                        .paused => .paused,
                    },
                    .value = progress.value,
                },
            };
        }

        /// Bounded graphics manifest sizing for one immutable observation cut.
        pub const GraphicsCounts = struct {
            images: u16,
            placements: u16,
            payload_bytes: usize,
        };

        /// Counts visible resources and placements without copying pixels.
        pub fn countGraphics(images: *const Images) error{ InvalidSnapshot, SnapshotTooLarge }!GraphicsCounts {
            if (images.cell_pixel_width == 0 or images.cell_pixel_height == 0)
                return error.InvalidSnapshot;
            var image_count: usize = 0;
            var image_index: usize = 0;
            while (image_index < images.imageCount()) : (image_index += 1) {
                const image = images.image(image_index) orelse return error.InvalidSnapshot;
                if (imageVisible(images, image.id)) image_count += 1;
            }
            var placement_count: usize = 0;
            // Images borrows one immutable cut. Count can scan Unicode-placeholder
            // cells, so never repeat that scan for each ordinary image placement.
            const placement_slots = images.placementCount();
            var placement_index: usize = 0;
            while (placement_index < placement_slots) : (placement_index += 1) {
                if (images.placement(placement_index) != null) placement_count += 1;
            }
            if (image_count > protocol.graphics_v2.maximum_images or
                placement_count > protocol.graphics_v2.maximum_placements)
                return error.InvalidSnapshot;
            const image_bytes = std.math.mul(usize, image_count, protocol.graphics_v2.image_bytes) catch
                return error.SnapshotTooLarge;
            const placement_bytes = std.math.mul(
                usize,
                placement_count,
                protocol.graphics_v2.placement_bytes,
            ) catch return error.SnapshotTooLarge;
            const payload_bytes = std.math.add(
                usize,
                protocol.graphics_v2.manifest_header_bytes + image_bytes,
                placement_bytes,
            ) catch return error.SnapshotTooLarge;
            return .{
                .images = @intCast(image_count),
                .placements = @intCast(placement_count),
                .payload_bytes = payload_bytes,
            };
        }

        /// Writes only bounded resource descriptors and visible placements.
        pub fn encodeGraphics(
            images: *const Images,
            counts: GraphicsCounts,
            output: []u8,
        ) error{InvalidSnapshot}!void {
            if (images.cell_pixel_width == 0 or images.cell_pixel_height == 0 or
                counts.images > protocol.graphics_v2.maximum_images or
                counts.placements > protocol.graphics_v2.maximum_placements or
                output.len != counts.payload_bytes)
                return error.InvalidSnapshot;
            const expected_bytes = protocol.graphics_v2.manifest_header_bytes +
                @as(usize, counts.images) * protocol.graphics_v2.image_bytes +
                @as(usize, counts.placements) * protocol.graphics_v2.placement_bytes;
            if (counts.payload_bytes != expected_bytes) return error.InvalidSnapshot;

            var header: [protocol.graphics_v2.manifest_header_bytes]u8 = undefined;
            protocol.encodeSnapshotGraphicsHeader(&header, .{
                .generation = images.generation,
                .content_generation = images.content_generation,
                .cell_pixel_width = images.cell_pixel_width,
                .cell_pixel_height = images.cell_pixel_height,
                .image_count = counts.images,
                .placement_count = counts.placements,
            });
            @memcpy(output[0..header.len], &header);
            var offset: usize = header.len;
            var image_count: usize = 0;
            var placement_count: usize = 0;

            var image_index: usize = 0;
            while (image_index < images.imageCount()) : (image_index += 1) {
                const image = images.image(image_index) orelse return error.InvalidSnapshot;
                if (!imageVisible(images, image.id)) continue;
                var encoded: [protocol.graphics_v2.image_bytes]u8 = undefined;
                protocol.encodeSnapshotImage(&encoded, .{
                    .image_id = image.id,
                    .generation = image.generation,
                    .width = image.width,
                    .height = image.height,
                });
                if (output.len - offset < encoded.len) return error.InvalidSnapshot;
                @memcpy(output[offset..][0..encoded.len], &encoded);
                offset += encoded.len;
                image_count += 1;
            }

            // Images borrows one immutable cut. Count can scan Unicode-placeholder
            // cells, so never repeat that scan for each ordinary image placement.
            const placement_slots = images.placementCount();
            var placement_index: usize = 0;
            while (placement_index < placement_slots) : (placement_index += 1) {
                const placement = images.placement(placement_index) orelse continue;
                if (!imagePresent(images, placement.image_id)) return error.InvalidSnapshot;
                var encoded: [protocol.graphics_v2.placement_bytes]u8 = undefined;
                protocol.encodeSnapshotImagePlacement(&encoded, .{
                    .image_id = placement.image_id,
                    .generation = placement.generation,
                    .row = placement.row,
                    .column = placement.col,
                    .source_x = placement.source_x,
                    .source_y = placement.source_y,
                    .source_width = placement.source_width,
                    .source_height = placement.source_height,
                    .cell_x = placement.cell_x,
                    .cell_y = placement.cell_y,
                    .pixel_width = placement.pixel_width,
                    .pixel_height = placement.pixel_height,
                    .z = placement.z,
                });
                if (output.len - offset < encoded.len) return error.InvalidSnapshot;
                @memcpy(output[offset..][0..encoded.len], &encoded);
                offset += encoded.len;
                placement_count += 1;
            }
            if (offset != output.len or image_count != counts.images or placement_count != counts.placements)
                return error.InvalidSnapshot;
        }

        /// Reports whether a resource participates in the borrowed visible manifest.
        pub fn imageVisible(images: *const Images, image_id: u32) bool {
            const placement_slots = images.placementCount();
            var index: usize = 0;
            while (index < placement_slots) : (index += 1) {
                const placement = images.placement(index) orelse continue;
                if (placement.image_id == image_id) return true;
            }
            return false;
        }

        fn imagePresent(images: *const Images, image_id: u32) bool {
            var index: usize = 0;
            while (index < images.imageCount()) : (index += 1) {
                const image = images.image(index) orelse continue;
                if (image.id == image_id) return true;
            }
            return false;
        }

        fn richLineGeometry(value: LineGeometry) u8 {
            return switch (value) {
                .single_width => 0,
                .double_width => 1,
                .double_height_top => 2,
                .double_height_bottom => 3,
            };
        }

        fn richBaseline(value: @TypeOf(@as(Cell, undefined).attrs.baseline)) u8 {
            return switch (value) {
                .normal => 0,
                .raised => 1,
                .lowered => 2,
            };
        }

        fn richUnderlineStyle(value: @TypeOf(@as(Cell, undefined).attrs.underline_style)) u8 {
            return switch (value) {
                .straight => 0,
                .double => 1,
                .curly => 2,
                .dotted => 3,
                .dashed => 4,
            };
        }

        fn richProtection(value: @TypeOf(@as(Cell, undefined).attrs.protected)) u8 {
            return switch (value) {
                .none => 0,
                .iso => 1,
                .dec => 2,
            };
        }

        fn richStyle(attrs: @TypeOf(@as(Cell, undefined).attrs)) u16 {
            var result: u16 = 0;
            if (attrs.bold) result |= protocol.text_v1.style.bold;
            if (attrs.dim) result |= protocol.text_v1.style.dim;
            if (attrs.italic) result |= protocol.text_v1.style.italic;
            if (attrs.blink) result |= protocol.text_v1.style.blink;
            if (attrs.blink_fast) result |= protocol.text_v1.style.blink_fast;
            if (attrs.reverse) result |= protocol.text_v1.style.reverse;
            if (attrs.invisible) result |= protocol.text_v1.style.invisible;
            if (attrs.underline) result |= protocol.text_v1.style.underline;
            if (attrs.strikethrough) result |= protocol.text_v1.style.strikethrough;
            return result;
        }

        fn encodeRichColor(output: []u8, color: @TypeOf(@as(Cell, undefined).attrs.fg)) !void {
            std.debug.assert(output.len == protocol.text_v1.color_bytes);
            const kind: protocol.TextColorKind = switch (color.colorKind()) {
                .default => .default,
                .indexed => .indexed,
                .rgb => .rgb,
            };
            var encoded: [protocol.text_v1.color_bytes]u8 = undefined;
            try protocol.encodeTextColor(&encoded, .{
                .kind = kind,
                .value = color.colorValue(),
            });
            @memcpy(output, &encoded);
        }

        fn appendRgba(
            allocator: std.mem.Allocator,
            output: *std.ArrayList(u8),
            rgb: @TypeOf(@as(Presentation, undefined).palette[0]),
        ) !void {
            try output.appendSlice(allocator, &.{ rgb.r, rgb.g, rgb.b, rgb.a });
        }

        fn appendOptionalRgba(
            allocator: std.mem.Allocator,
            output: *std.ArrayList(u8),
            rgb: ?@TypeOf(@as(Presentation, undefined).palette[0]),
        ) !void {
            if (rgb) |value| return appendRgba(allocator, output, value);
            try output.appendSlice(allocator, &.{ 0, 0, 0, 0 });
        }
    };
}

const TextRecordOffsets = struct {
    record_header: usize,
    payload_start: usize,
    kind: protocol.TextRecordKind,
};

fn beginTextRecord(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    kind: protocol.TextRecordKind,
) !TextRecordOffsets {
    const record_header = output.items.len;
    if (record_header > protocol.maximum_text_snapshot_bytes - protocol.text_v1.record_header_bytes)
        return error.SnapshotTooLarge;
    try output.appendNTimes(allocator, 0, protocol.text_v1.record_header_bytes);
    return .{
        .record_header = record_header,
        .payload_start = output.items.len,
        .kind = kind,
    };
}

fn finishTextRecord(output: *std.ArrayList(u8), offsets: TextRecordOffsets) !void {
    if (output.items.len > protocol.maximum_text_snapshot_bytes) return error.SnapshotTooLarge;
    const payload_len = output.items.len - offsets.payload_start;
    var header: [protocol.text_v1.record_header_bytes]u8 = undefined;
    protocol.encodeTextRecordHeader(&header, .{ .kind = offsets.kind, .payload_len = @intCast(payload_len) });
    @memcpy(output.items[offsets.record_header..offsets.payload_start], &header);
}

fn encodeU64(output: []u8, value: u64) void {
    std.debug.assert(output.len == 8);
    output[0] = @truncate(value >> 56);
    output[1] = @truncate(value >> 48);
    output[2] = @truncate(value >> 40);
    output[3] = @truncate(value >> 32);
    output[4] = @truncate(value >> 24);
    output[5] = @truncate(value >> 16);
    output[6] = @truncate(value >> 8);
    output[7] = @truncate(value);
}

fn encodeU32(output: []u8, value: u32) void {
    std.debug.assert(output.len == 4);
    output[0] = @truncate(value >> 24);
    output[1] = @truncate(value >> 16);
    output[2] = @truncate(value >> 8);
    output[3] = @truncate(value);
}

test "delta hyperlink memberships preserve bounded identities and merge exactly" {
    var rows: [3]Links = @splat(@splat(0));
    const first_id: u32 = 1;
    const last_id: u32 = protocol.text_v1.maximum_hyperlinks;
    try noteLink(first_id, &rows[0]);
    try noteLink(last_id, &rows[1]);
    var merged: Links = @splat(0);
    mergeLinks(&merged, &rows[0]);
    mergeLinks(&merged, &rows[1]);
    try std.testing.expect((merged[first_id / 64] & (@as(u64, 1) << @as(u6, @intCast(first_id % 64)))) != 0);
    try std.testing.expect((merged[last_id / 64] & (@as(u64, 1) << @as(u6, @intCast(last_id % 64)))) != 0);
    for (rows[2]) |word| try std.testing.expectEqual(@as(u64, 0), word);
    try std.testing.expectError(error.InvalidSnapshot, noteLink(last_id + 1, &rows[2]));
    for (rows[2]) |word| try std.testing.expectEqual(@as(u64, 0), word);
    try std.testing.expectError(error.InvalidSnapshot, noteLink(first_id, rows[2][0..1]));
}
