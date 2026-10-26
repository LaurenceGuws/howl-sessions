//! Proves directly borrowed observations against the published canonical VT root.
const std = @import("std");
const vt = @import("howl_vt");
const codec = @import("terminal_observation_codec");
const Encoder = codec.encoder.Encoder(vt.Terminal.Observation);

fn fixture(allocator: std.mem.Allocator) !vt.Terminal {
    var terminal = try vt.Terminal.init(allocator, 2, 8);
    errdefer terminal.deinit();
    try std.testing.expect((try terminal.feed("\x1b]2;copybook\x07\x1b[31m\x1b]8;;https://example.invalid/\x07A\xcc\x81\x1b]8;;\x07B")).stateChanged());
    return terminal;
}

test "optional encoder preserves VT facts and never advances canonical state" {
    var terminal = try fixture(std.testing.allocator);
    defer terminal.deinit();
    const sequence = terminal.semanticSequence();
    const semantic = terminal.observation().semanticView(0);
    const metadata = Encoder.metadata(semantic, sequence);
    try std.testing.expectEqual(sequence, metadata.revision);
    try std.testing.expectEqual(semantic.rows, metadata.rows);
    try std.testing.expectEqual(semantic.cols, metadata.columns);
    try std.testing.expectEqual(semantic.cursor_row, metadata.cursor_row);
    try std.testing.expectEqual(semantic.cursor_col, metadata.cursor_column);
    try std.testing.expectEqual(semantic.history_count, metadata.history_count);
    try std.testing.expectEqual(semantic.history_row_base, metadata.history_row_base);
    try std.testing.expectEqual(semantic.cursor_visible, metadata.cursor_visible);
    try std.testing.expectEqual(semantic.cursor_blink, metadata.cursor_blink);
    try std.testing.expectEqual(semantic.is_alternate_screen, metadata.alternate_screen);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    const geometry = try Encoder.appendText(std.testing.allocator, &body, terminal.observation(), 0, 42);
    try std.testing.expectEqual(sequence, terminal.semanticSequence());
    var text = try codec.text.decode(std.testing.allocator, geometry, .raw, body.items);
    defer text.deinit();
    try std.testing.expectEqual(@as(?u64, 42), text.presentation.cursor_age_ns);
    try std.testing.expectEqualSlices(u32, &.{ 'A', 0x0301 }, text.rows[0].cells[0].scalars);
    try std.testing.expectEqual(codec.TextColorKind.indexed, text.rows[0].cells[0].foreground.kind);
    try std.testing.expectEqual(@as(u32, 1), text.rows[0].cells[0].foreground.value);
    try std.testing.expectEqual(@as(usize, 1), text.hyperlinks.len);
    try std.testing.expectEqualStrings("https://example.invalid/", text.hyperlinks[0].uri_bytes);
    try std.testing.expectEqual(@as(u32, 'B'), text.rows[0].cells[1].scalars[0]);
    try std.testing.expectEqual(@as(u32, 0), text.rows[0].cells[1].link_id);
    const properties = Encoder.properties(terminal.observation());
    var packet: [codec.properties.maximum_bytes]u8 = undefined;
    const size = try codec.properties.encode(&packet, properties);
    const decoded = try codec.properties.decode(packet[0..size]);
    try std.testing.expectEqualStrings("copybook", decoded.title.?);
}

fn testEncodeAllocation(allocator: std.mem.Allocator, observation: *const vt.Terminal.Observation) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "prefix");
    const sequence = observation.semanticSequence();
    const geometry = Encoder.appendText(allocator, &body, observation, 0, 42) catch |err| {
        try std.testing.expectEqualStrings("prefix", body.items);
        try std.testing.expectEqual(sequence, observation.semanticSequence());
        return err;
    };
    try std.testing.expect(body.items.len > "prefix".len);
    try std.testing.expectEqual(@as(u16, 2), geometry.rows);
    try std.testing.expectEqual(@as(u16, 8), geometry.columns);
    try std.testing.expectEqual(sequence, observation.semanticSequence());
}

fn testRowAllocation(allocator: std.mem.Allocator, observation: *const vt.Terminal.Observation) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "prefix");
    var links: codec.encoder.Links = @splat(0);
    try codec.encoder.noteLink(4096, &links);
    const before = links;
    Encoder.appendRow(allocator, &body, observation.semanticView(0), 0, &links) catch |err| {
        try std.testing.expectEqualStrings("prefix", body.items);
        try std.testing.expectEqualSlices(u64, &before, &links);
        return err;
    };
    try std.testing.expect(links[0] != before[0]);
}

test "encoding allocation failures restore prefixes and row link membership" {
    var terminal = try fixture(std.testing.allocator);
    defer terminal.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testEncodeAllocation, .{terminal.observation()});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testRowAllocation, .{terminal.observation()});
}

test "optional encoder retains the complete 24-scalar VT cluster" {
    var terminal = try vt.Terminal.init(std.testing.allocator, 1, 2);
    defer terminal.deinit();
    try std.testing.expect((try terminal.feed("e")).stateChanged());
    for (0..vt.scalar.maximum_scalars - 1) |_| try std.testing.expect((try terminal.feed("\xcc\x81")).stateChanged());
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    const geometry = try Encoder.appendText(std.testing.allocator, &body, terminal.observation(), 0, 0);
    var text = try codec.text.decode(std.testing.allocator, geometry, .raw, body.items);
    defer text.deinit();
    try std.testing.expectEqual(vt.scalar.maximum_scalars, text.rows[0].cells[0].scalars.len);
    try std.testing.expectEqual(@as(u32, 'e'), text.rows[0].cells[0].scalars[0]);
    for (text.rows[0].cells[0].scalars[1..]) |scalar| try std.testing.expectEqual(@as(u32, 0x0301), scalar);
    var cache = codec.cache.Cache.init(std.testing.allocator);
    defer cache.deinit();
    const cached = try cache.decode(geometry, .full, body.items);
    const metadata = Encoder.metadata(terminal.observation().semanticView(0), terminal.semanticSequence());
    const owned = try codec.view.project(std.testing.allocator, &.{
        .metadata = &metadata,
        .presentation = &cached.presentation,
        .rows = cached.rows,
        .hyperlinks = cached.hyperlinks,
        .changed_rows = cached.changed_rows,
        .row_shift = cached.row_shift,
    });
    defer codec.view.deinit(owned);
    const scalars = cached.rows[0].cells[0].scalars;
    try std.testing.expectEqualSlices(u32, text.rows[0].cells[0].scalars, scalars);
    var delta: std.ArrayList(u8) = .empty;
    defer delta.deinit(std.testing.allocator);
    try delta.appendSlice(std.testing.allocator, body.items[0 .. codec.text_v1.record_header_bytes + codec.text_v1.presentation_bytes]);
    try codec.encoder.appendRowShift(std.testing.allocator, &delta, 0);
    try codec.encoder.appendRowReuse(std.testing.allocator, &delta);
    const reused = try cache.decode(geometry, .delta, delta.items);
    try std.testing.expectEqual(scalars.ptr, reused.rows[0].cells[0].scalars.ptr);
    try std.testing.expectEqualSlices(u32, scalars, reused.rows[0].cells[0].scalars);
    try std.testing.expectEqualSlices(bool, &.{false}, reused.changed_rows);
    cache.invalidate();
    try std.testing.expectEqual(metadata.revision, codec.view.metadata(owned).revision);
    try std.testing.expectEqual(vt.scalar.maximum_scalars, codec.view.scalars(owned).len);
    try std.testing.expectEqual(@as(u32, 'e'), codec.view.scalars(owned)[0]);
    for (codec.view.scalars(owned)[1..]) |scalar| try std.testing.expectEqual(@as(u32, 0x0301), scalar);
    try std.testing.expectEqualSlices(bool, &.{true}, codec.view.changedRows(owned).?);
}

test "optional encoder bounds output without changing its caller's prefix" {
    var terminal = try fixture(std.testing.allocator);
    defer terminal.deinit();
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    try body.appendNTimes(std.testing.allocator, 0x5a, codec.maximum_text_snapshot_bytes);
    try std.testing.expectError(error.SnapshotTooLarge, Encoder.appendText(
        std.testing.allocator,
        &body,
        terminal.observation(),
        0,
        0,
    ));
    try std.testing.expectEqual(codec.maximum_text_snapshot_bytes, body.items.len);
    for (body.items) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
    body.clearRetainingCapacity();
    var links: codec.encoder.Links = @splat(0);
    try std.testing.expectError(error.InvalidSnapshot, Encoder.appendRow(
        std.testing.allocator,
        &body,
        terminal.observation().semanticView(0),
        2,
        &links,
    ));
    try std.testing.expectEqual(@as(usize, 0), body.items.len);
}

test "optional encoder exports a graphics manifest independently of delivery" {
    var terminal = try fixture(std.testing.allocator);
    defer terminal.deinit();
    var images = terminal.observation().images(0);
    try std.testing.expectError(error.InvalidSnapshot, Encoder.countGraphics(&images));
    var missing: [codec.graphics_v2.manifest_header_bytes]u8 = undefined;
    try std.testing.expectError(error.InvalidSnapshot, Encoder.encodeGraphics(
        &images,
        .{ .images = 0, .placements = 0, .payload_bytes = missing.len },
        &missing,
    ));
    try terminal.setCellPixelSize(10, 20);
    images = terminal.observation().images(0);
    const counts = try Encoder.countGraphics(&images);
    const packet = try std.testing.allocator.alloc(u8, counts.payload_bytes);
    defer std.testing.allocator.free(packet);
    var wrong = counts;
    wrong.images = 1;
    try std.testing.expectError(error.InvalidSnapshot, Encoder.encodeGraphics(&images, wrong, packet));
    try Encoder.encodeGraphics(&images, counts, packet);
    var graphics = try codec.decoded.decodeGraphics(
        std.testing.allocator,
        .{ .rows = 2, .columns = 8 },
        packet,
    );
    defer graphics.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), graphics.images.len);
    try std.testing.expectEqual(@as(usize, 0), graphics.placements.len);
}

fn expectDeltaMatches(
    publisher: *Encoder.DeltaCache,
    receiver: *codec.cache.Cache,
    terminal: *const vt.Terminal.Observation,
    history_offset: u32,
    allow_reuse: bool,
    expected_mode: Encoder.DeltaCache.Mode,
) !codec.cache.View {
    const allocator = std.testing.allocator;
    const sequence = terminal.semanticSequence();
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(allocator);
    const mode = try publisher.appendText(allocator, &encoded, terminal, history_offset, 42, allow_reuse);
    try std.testing.expectEqual(expected_mode, mode);
    const view = terminal.semanticView(history_offset);
    const geometry = codec.decoded.Geometry{ .rows = view.rows, .columns = view.cols };
    const reused = try receiver.decode(geometry, if (mode == .full) .full else .delta, encoded.items);
    var full: std.ArrayList(u8) = .empty;
    defer full.deinit(allocator);
    const full_geometry = try Encoder.appendText(allocator, &full, terminal, history_offset, 42);
    try std.testing.expectEqualDeep(geometry, full_geometry);
    var expected = try codec.text.decode(allocator, geometry, .raw, full.items);
    defer expected.deinit();
    try std.testing.expectEqualDeep(expected.presentation, reused.presentation);
    try std.testing.expectEqualDeep(expected.rows, reused.rows);
    try std.testing.expectEqualDeep(expected.hyperlinks, reused.hyperlinks);
    try std.testing.expectEqual(sequence, terminal.semanticSequence());
    return reused;
}

test "delta retention uses compact live provenance and independent caller authorization" {
    var terminal = try fixture(std.testing.allocator);
    defer terminal.deinit();
    var publisher: Encoder.DeltaCache = .{};
    defer publisher.deinit(std.testing.allocator);
    var receiver = codec.cache.Cache.init(std.testing.allocator);
    defer receiver.deinit();
    const full = try expectDeltaMatches(&publisher, &receiver, terminal.observation(), 0, true, .full);
    try std.testing.expectEqualSlices(bool, &.{ true, true }, full.changed_rows);
    try std.testing.expectEqual(@as(usize, 0), publisher.cells.len);
    try std.testing.expectEqual(@as(usize, 2), publisher.entries.len);
    try std.testing.expectEqual(@as(usize, 2 * codec.encoder.link_word_count), publisher.links.len);
    for (publisher.entries) |entry| {
        try std.testing.expect(entry.valid);
        try std.testing.expect(entry.generation != null);
    }
    const retained_entries = publisher.entries.ptr;
    const retained_links = publisher.links.ptr;
    const unchanged = try expectDeltaMatches(&publisher, &receiver, terminal.observation(), 0, true, .delta);
    try std.testing.expectEqualSlices(bool, &.{ false, false }, unchanged.changed_rows);
    try std.testing.expectEqual(retained_entries, publisher.entries.ptr);
    try std.testing.expectEqual(retained_links, publisher.links.ptr);
    try std.testing.expect((try terminal.feed("\x1b[2;1HZ")).stateChanged());
    const edited = try expectDeltaMatches(&publisher, &receiver, terminal.observation(), 0, true, .delta);
    try std.testing.expectEqualSlices(bool, &.{ false, true }, edited.changed_rows);
    const denied = try expectDeltaMatches(&publisher, &receiver, terminal.observation(), 0, false, .full);
    try std.testing.expectEqualSlices(bool, &.{ false, false }, denied.changed_rows);
    try terminal.resize(3, 10);
    const resized = try expectDeltaMatches(&publisher, &receiver, terminal.observation(), 0, true, .full);
    try std.testing.expectEqual(@as(usize, 3), resized.rows.len);
    try std.testing.expectEqual(@as(usize, 0), publisher.cells.len);
}

test "delta upward rotation preserves reused row hyperlinks and exact terminal cells" {
    var terminal = try vt.Terminal.initWithHistory(std.testing.allocator, 3, 8, 8);
    defer terminal.deinit();
    try std.testing.expect((try terminal.feed("A\x1b[2;1H\x1b]8;;https://example.invalid/retained\x07B\x1b]8;;\x07\x1b[3;1HC")).stateChanged());
    var publisher: Encoder.DeltaCache = .{};
    defer publisher.deinit(std.testing.allocator);
    var receiver = codec.cache.Cache.init(std.testing.allocator);
    defer receiver.deinit();
    const baseline = try expectDeltaMatches(&publisher, &receiver, terminal.observation(), 0, false, .full);
    try std.testing.expectEqual(@as(?u16, null), baseline.row_shift);
    try std.testing.expect((try terminal.feed("\r\nD")).stateChanged());
    const rotated = try expectDeltaMatches(&publisher, &receiver, terminal.observation(), 0, true, .delta);
    try std.testing.expectEqual(@as(?u16, 1), rotated.row_shift);
    try std.testing.expectEqualSlices(bool, &.{ false, false, true }, rotated.changed_rows);
    try std.testing.expectEqual(@as(u32, 'B'), rotated.rows[0].cells[0].scalars[0]);
    try std.testing.expectEqual(@as(usize, 1), rotated.hyperlinks.len);
    try std.testing.expectEqualStrings("https://example.invalid/retained", rotated.hyperlinks[0].uri_bytes);
    try std.testing.expectEqual(rotated.hyperlinks[0].link_id, rotated.rows[0].cells[0].link_id);
    try std.testing.expect((try terminal.feed("\r\nE\r\nF\r\nG")).stateChanged());
    const jumped = try expectDeltaMatches(&publisher, &receiver, terminal.observation(), 0, true, .delta);
    try std.testing.expectEqual(@as(?u16, null), jumped.row_shift);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true }, jumped.changed_rows);
    try std.testing.expectEqual(@as(usize, 0), jumped.hyperlinks.len);
}

test "delta provenance cannot cross primary and alternate screen generation namespaces" {
    var terminal = try vt.Terminal.init(std.testing.allocator, 2, 8);
    defer terminal.deinit();
    try std.testing.expect((try terminal.feed("A")).stateChanged());
    var publisher: Encoder.DeltaCache = .{};
    defer publisher.deinit(std.testing.allocator);
    var receiver = codec.cache.Cache.init(std.testing.allocator);
    defer receiver.deinit();
    const baseline = try expectDeltaMatches(&publisher, &receiver, terminal.observation(), 0, false, .full);
    try std.testing.expectEqual(@as(?u16, null), baseline.row_shift);
    const primary_generation = terminal.observation().semanticView(0).rowGeneration(0);
    try std.testing.expect((try terminal.feed("\x1b[?47hB")).stateChanged());
    const alternate = terminal.observation().semanticView(0);
    try std.testing.expect(alternate.is_alternate_screen);
    // Equal numeric generations belong to distinct screen banks and different cells.
    try std.testing.expectEqual(primary_generation, alternate.rowGeneration(0));
    const switched = try expectDeltaMatches(&publisher, &receiver, terminal.observation(), 0, true, .full);
    try std.testing.expectEqual(@as(u32, 'B'), switched.rows[0].cells[0].scalars[0]);
    try std.testing.expect((try terminal.feed("\x1b[?47l")).stateChanged());
    const restored = try expectDeltaMatches(&publisher, &receiver, terminal.observation(), 0, true, .full);
    try std.testing.expectEqual(@as(u32, 'A'), restored.rows[0].cells[0].scalars[0]);
}

test "historical delta fallback retains exact cells and reencodes sidecar scalar clusters" {
    var terminal = try vt.Terminal.initWithHistory(std.testing.allocator, 3, 8, 8);
    defer terminal.deinit();
    try std.testing.expect((try terminal.feed("e")).stateChanged());
    for (0..vt.scalar.maximum_scalars - 1) |_| try std.testing.expect((try terminal.feed("\xcc\x81")).stateChanged());
    try std.testing.expect((try terminal.feed("\r\nB\r\nC\r\nD")).stateChanged());
    var publisher: Encoder.DeltaCache = .{};
    defer publisher.deinit(std.testing.allocator);
    var receiver = codec.cache.Cache.init(std.testing.allocator);
    defer receiver.deinit();
    const baseline = try expectDeltaMatches(&publisher, &receiver, terminal.observation(), 1, false, .full);
    try std.testing.expectEqual(@as(?u16, null), baseline.row_shift);
    try std.testing.expectEqual(@as(usize, 3 * 8), publisher.cells.len);
    for (publisher.entries) |entry| try std.testing.expectEqual(@as(?u64, null), entry.generation);
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(Encoder.DeltaCache.Mode.delta, try publisher.appendText(std.testing.allocator, &encoded, terminal.observation(), 1, 42, true));
    const first_row_offset = codec.text_v1.record_header_bytes + codec.text_v1.presentation_bytes +
        codec.text_v1.record_header_bytes + codec.text_delta_v2.row_shift_bytes;
    var row_header: [codec.text_v1.record_header_bytes]u8 = undefined;
    @memcpy(&row_header, encoded.items[first_row_offset..][0..row_header.len]);
    const first_row = try codec.decodeTextRecordHeader(&row_header);
    try std.testing.expectEqual(codec.TextRecordKind.row, first_row.kind);
    try std.testing.expect(first_row.payload_len > codec.text_v1.row_header_bytes);
    const again = try expectDeltaMatches(&publisher, &receiver, terminal.observation(), 1, true, .delta);
    // The literal sidecar row may compare equal after decode, but must be encoded.
    try std.testing.expectEqual(@as(usize, vt.scalar.maximum_scalars), again.rows[0].cells[0].scalars.len);
    try std.testing.expect((try terminal.feed("\r\nE")).stateChanged());
    const rotated = try expectDeltaMatches(&publisher, &receiver, terminal.observation(), 1, true, .delta);
    try std.testing.expectEqual(@as(?u16, 1), rotated.row_shift);
    try std.testing.expectEqual(@as(u32, 'B'), rotated.rows[0].cells[0].scalars[0]);
    const live = try expectDeltaMatches(&publisher, &receiver, terminal.observation(), 0, true, .full);
    try std.testing.expectEqual(@as(?u16, null), live.row_shift);
    try std.testing.expectEqual(@as(usize, 0), publisher.cells.len);
}

fn testDeltaAllocation(allocator: std.mem.Allocator, observation: *const vt.Terminal.Observation) !void {
    var publisher: Encoder.DeltaCache = .{};
    defer publisher.deinit(allocator);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    const sequence = observation.semanticSequence();
    for ([_]u32{ 0, 1 }) |offset| {
        body.clearAndFree(allocator);
        try body.appendSlice(allocator, "prefix");
        const mode = publisher.appendText(allocator, &body, observation, offset, 0, true) catch |err| {
            try std.testing.expectEqualStrings("prefix", body.items);
            try std.testing.expect(!publisher.complete);
            for (publisher.entries) |entry| try std.testing.expect(!entry.valid);
            try std.testing.expectEqual(@as(?u64, null), publisher.row_origin);
            try std.testing.expectEqual(sequence, observation.semanticSequence());
            return err;
        };
        try std.testing.expectEqual(Encoder.DeltaCache.Mode.full, mode);
        try std.testing.expect(publisher.complete);
        try std.testing.expectEqual(sequence, observation.semanticSequence());
    }
}

test "delta allocation failures revoke retained facts and preserve the caller prefix" {
    var terminal = try vt.Terminal.initWithHistory(std.testing.allocator, 3, 8, 8);
    defer terminal.deinit();
    try std.testing.expect((try terminal.feed("\x1b]8;;https://example.invalid/failure\x07A\x1b]8;;\x07\r\nB\r\nC\r\nD")).stateChanged());
    // Number every buffer growth as an allocation, independently of the backing
    // allocator's resize/remap successes. Every failure point stays reachable.
    var allocation_only = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(allocation_only.allocator(), testDeltaAllocation, .{terminal.observation()});
    var publisher: Encoder.DeltaCache = .{};
    defer publisher.deinit(std.testing.allocator);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    try std.testing.expectEqual(Encoder.DeltaCache.Mode.full, try publisher.appendText(std.testing.allocator, &body, terminal.observation(), 0, 0, false));
    body.clearRetainingCapacity();
    try body.appendNTimes(std.testing.allocator, 0x5a, codec.maximum_text_snapshot_bytes);
    try std.testing.expectError(error.SnapshotTooLarge, publisher.appendText(std.testing.allocator, &body, terminal.observation(), 0, 0, true));
    try std.testing.expectEqual(codec.maximum_text_snapshot_bytes, body.items.len);
    for (body.items) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
    try std.testing.expect(!publisher.complete);
    for (publisher.entries) |entry| try std.testing.expect(!entry.valid);
    body.clearRetainingCapacity();
    try std.testing.expectEqual(Encoder.DeltaCache.Mode.full, try publisher.appendText(std.testing.allocator, &body, terminal.observation(), 0, 0, true));
    publisher.invalidate();
    try std.testing.expectEqual(Encoder.DeltaCache.Mode.full, try publisher.appendText(std.testing.allocator, &body, terminal.observation(), 0, 0, true));
}
