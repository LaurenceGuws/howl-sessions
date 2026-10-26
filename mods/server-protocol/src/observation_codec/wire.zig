//! Transport-neutral terminal observation payload grammar.
//!
//! Protocol owns portable records and exact payload validation because neither
//! depends on how a canonical VT is run or where a client presents the result.
//! This grammar owns no parser, socket, Server identity, or presentation.
const std = @import("std");

/// Complete bounded terminal properties; decoded slices borrow their packet.
pub const properties = @import("properties.zig");
/// Hard ceiling for one complete encoded/decoded semantic text observation.
pub const maximum_text_snapshot_bytes: usize = 4 * 1024 * 1024;
/// Rejects malformed or noncanonical observation payloads.
pub const PayloadError = error{InvalidPayload};

/// Self-delimiting record tags shared by full and explicit delta observations.
pub const TextRecordKind = enum(u8) {
    presentation = 1,
    row = 2,
    hyperlink = 3,
    /// Delta-only baseline rotation applied before row reuse markers.
    row_shift = 4,
};

/// One self-delimiting `text_v1` record header. Reserved bytes are always zero.
pub const TextRecordHeader = struct {
    kind: TextRecordKind,
    payload_len: u32,
};

/// Stable language-neutral terminal color classes used by `text_v1` cells.
pub const TextColorKind = enum(u8) {
    default = 0,
    indexed = 1,
    rgb = 2,
};

/// One semantic terminal color. RGB values use the low 24 bits as 0xRRGGBB.
pub const TextColor = struct {
    kind: TextColorKind,
    value: u32,
};

/// Frozen byte grammar and bounds for the renderer-neutral rich text snapshot.
pub const text_v1 = struct {
    /// Uncompressed body length prefix before the zlib stream, big-endian u32.
    pub const compressed_header_bytes: usize = 4;
    /// Fixed record header: kind:u8, reserved:u24=0, payload_len:u32 big-endian.
    pub const record_header_bytes: usize = 8;
    /// Semantic color: kind:u8 followed by value:u32 big-endian.
    pub const color_bytes: usize = 5;
    /// Exact fixed presentation payload; this record has no variable suffix.
    pub const presentation_bytes: usize = 8 + 1 + 1 + 2 +
        256 * 4 + 2 * 4 + 4 * 4;
    /// Cursor-age sentinel when no tracked absolute movement has occurred.
    pub const no_cursor_movement_age_ns: u64 = std.math.maxInt(u64);
    /// Row prefix: wrapped:u8, DEC line geometry:u8, columns:u16 big-endian.
    pub const row_header_bytes: usize = 4;
    /// Fixed cell prefix followed by `scalar_count` big-endian u32 scalars.
    pub const cell_header_bytes: usize = 35;
    /// Hyperlink prefix: stable link_id:u32 + uri_len:u16, both big-endian.
    pub const hyperlink_header_bytes: usize = 6;
    /// Frozen maximum Unicode scalars transported for one terminal grapheme.
    pub const maximum_cell_scalars: u8 = 24;
    /// Frozen maximum referenced OSC 8 identities in one snapshot.
    pub const maximum_hyperlinks: u16 = 4096;
    /// Frozen maximum URI bytes for one transported OSC 8 target.
    pub const maximum_hyperlink_uri_bytes: u16 = 2048;

    /// Optional presentation colors whose four RGBA slots are always present.
    pub const presentation_presence = struct {
        /// Cursor-color RGBA slot is semantically present.
        pub const cursor: u8 = 1 << 0;
        /// Cursor-text RGBA slot is semantically present.
        pub const cursor_text: u8 = 1 << 1;
        /// Selection-background RGBA slot is semantically present.
        pub const selection_background: u8 = 1 << 2;
        /// Selection-foreground RGBA slot is semantically present.
        pub const selection_foreground: u8 = 1 << 3;
        /// Mask of every accepted `text_v1` presentation-presence bit.
        pub const known: u8 = cursor | cursor_text |
            selection_background | selection_foreground;
    };

    /// Terminal-wide presentation flags.
    pub const presentation_flags = struct {
        /// DEC reverse-video mode applies to the complete presentation.
        pub const reverse_screen: u8 = 1 << 0;
        /// Mask of every accepted `text_v1` presentation flag.
        pub const known: u8 = reverse_screen;
    };

    /// Cell style flags. Spare bits must remain zero for `text_v1`.
    pub const style = struct {
        /// SGR bold rendition is active.
        pub const bold: u16 = 1 << 0;
        /// SGR dim rendition is active.
        pub const dim: u16 = 1 << 1;
        /// SGR italic rendition is active.
        pub const italic: u16 = 1 << 2;
        /// Slow blink rendition is active.
        pub const blink: u16 = 1 << 3;
        /// Fast blink rendition is active.
        pub const blink_fast: u16 = 1 << 4;
        /// Cell foreground/background semantic reversal is active.
        pub const reverse: u16 = 1 << 5;
        /// Invisible/conceal rendition is active.
        pub const invisible: u16 = 1 << 6;
        /// Underline rendition is active; style is carried separately.
        pub const underline: u16 = 1 << 7;
        /// Strikethrough rendition is active.
        pub const strikethrough: u16 = 1 << 8;
        /// Mask of every accepted `text_v1` cell-style bit.
        pub const known: u16 = bold | dim | italic | blink | blink_fast |
            reverse | invisible | underline | strikethrough;
    };
};

/// Frozen delta-only additions layered over complete `text_v1` records.
///
/// Every framing-v7 `snapshot_delta_data` body carries exactly one row-shift
/// record after presentation and before rows. Zero means no viewport movement;
/// positive values rotate the named baseline upward before row reuse markers
/// are interpreted. Complete raw/compressed `text_v1` bodies never carry it.
pub const text_delta_v2 = struct {
    /// Big-endian visible rows shifted upward from the named baseline.
    pub const row_shift_bytes: usize = 2;
};

/// Lossless transport packing for complete `text_v1` bodies.
///
/// This is not a second semantic terminal representation. Record headers,
/// presentation bytes, hyperlink bytes, cell attributes and Unicode scalars
/// reconstruct byte-for-byte to the frozen `text_v1` grammar before semantic
/// decoding. Only complete row payload carriage changes.
pub const text_pack_v1 = struct {
    /// Original text_v1 bytes followed by packed bytes in the compressed envelope.
    pub const compressed_header_bytes: usize = 8;
    /// One row carriage discriminator after the preserved text_v1 record header.
    pub const row_mode_bytes: usize = 1;
    /// A text_v1 cell header without its per-cell scalar-count byte.
    pub const cell_attribute_bytes: usize = text_v1.cell_header_bytes - 1;
    /// Packed-run prefix: cells in run, both big-endian u16.
    pub const run_count_bytes: usize = 2;
    /// Number of consecutive cells owned by one attribute run, big-endian u16.
    pub const run_length_bytes: usize = 2;
    /// Worst case uses verbatim rows and adds one mode byte per visible row.
    pub const maximum_body_bytes: usize = maximum_text_snapshot_bytes + std.math.maxInt(u16);

    /// Per-row carriage chosen independently so pathological rich rows may fall
    /// back without expanding beyond one discriminator byte.
    pub const RowMode = enum(u8) {
        /// Carries the original frozen text_v1 row payload unchanged.
        verbatim = 0,
        /// Carries exact consecutive attribute runs plus cell scalar data.
        runs = 1,
    };
};

/// Frozen image-resource and visible-placement grammar introduced with framing v4.
///
/// `text_v1` remains byte-for-byte unchanged. A snapshot carries one separate
/// `snapshot_graphics` frame containing only lightweight resource identities and
/// visible placements. Exact RGBA8 pixels are fetched on demand by image id and
/// content generation, so the 4 MiB snapshot bound never competes with the
/// canonical terminal's larger decoded-image quota.
pub const graphics_v2 = struct {
    /// Fixed snapshot graphics prefix: plane generation, content generation,
    /// image descriptor count, placement count.
    pub const manifest_header_bytes: usize = 28;
    /// One visible referenced image: id, content generation, width, height.
    pub const image_bytes: usize = 20;
    /// One visible placement resolved to viewport row/column and pixel geometry.
    pub const placement_bytes: usize = 52;
    /// Bounds image identities in one canonical terminal graphics plane.
    pub const maximum_images: usize = 256;
    /// Bounds placements in one canonical terminal graphics plane.
    pub const maximum_placements: usize = 16 * 1024;
    /// Bounds either decoded image dimension.
    pub const maximum_dimension: u32 = 4096;
    /// Bounds one exact decoded RGBA8 resource body.
    pub const maximum_image_bytes: usize = 16 * 1024 * 1024;
    /// Largest possible lightweight graphics manifest payload.
    pub const maximum_manifest_bytes: usize = manifest_header_bytes +
        maximum_images * image_bytes + maximum_placements * placement_bytes;
};

/// Snapshot graphics prefix shared by the lightweight manifest codecs.
pub const SnapshotGraphicsHeader = struct {
    generation: u64,
    content_generation: u64,
    cell_pixel_width: u32,
    cell_pixel_height: u32,
    image_count: u16,
    placement_count: u16,
};

/// One image resource identity referenced by a visible placement.
pub const SnapshotImage = struct {
    image_id: u32,
    generation: u64,
    width: u32,
    height: u32,
};

/// One image placement resolved into the current snapshot viewport.
pub const SnapshotImagePlacement = struct {
    image_id: u32,
    generation: u64,
    row: u16,
    column: u16,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
    cell_x: u32,
    cell_y: u32,
    pixel_width: u32,
    pixel_height: u32,
    z: i32,
};

/// Encodes one self-delimiting `text_v1` record header.
pub fn encodeTextRecordHeader(
    output: *[text_v1.record_header_bytes]u8,
    value: TextRecordHeader,
) void {
    output.* = @splat(0);
    output[0] = @backingInt(value.kind);
    writeU32(output[4..8], value.payload_len);
}

/// Decodes one `text_v1` record header and rejects every reserved bit.
pub fn decodeTextRecordHeader(
    input: *const [text_v1.record_header_bytes]u8,
) PayloadError!TextRecordHeader {
    if (input[1] != 0 or input[2] != 0 or input[3] != 0)
        return error.InvalidPayload;
    return .{
        .kind = enumFromInt(TextRecordKind, input[0]) orelse
            return error.InvalidPayload,
        .payload_len = readU32(input[4..8]),
    };
}

/// Exact failure surface for lossless text_v1 transport packing/unpacking.
pub const TextPackError = PayloadError || std.mem.Allocator.Error || error{
    SnapshotTooLarge,
};

fn textCellRecordBytes(encoded: []const u8) TextPackError!usize {
    if (encoded.len < text_v1.cell_header_bytes) return error.InvalidPayload;
    const scalar_count = encoded[0];
    if (scalar_count > text_v1.maximum_cell_scalars) return error.InvalidPayload;
    return std.math.add(
        usize,
        text_v1.cell_header_bytes,
        @as(usize, scalar_count) * @sizeOf(u32),
    ) catch return error.InvalidPayload;
}

fn packedRowRunSize(payload: []const u8) TextPackError!usize {
    if (payload.len < text_v1.row_header_bytes) return error.InvalidPayload;
    const columns = readU16(payload[2..4]);
    var packed_size = text_pack_v1.row_mode_bytes + text_v1.row_header_bytes + text_pack_v1.run_count_bytes;
    var offset: usize = text_v1.row_header_bytes;
    var column: u16 = 0;
    var run_count: usize = 0;
    while (column < columns) {
        if (payload.len - offset < text_v1.cell_header_bytes) return error.InvalidPayload;
        const attributes = payload[offset + 1 .. offset + text_v1.cell_header_bytes];
        var run_cells: u16 = 0;
        var run_scalars: usize = 0;
        while (column < columns) {
            if (payload.len - offset < text_v1.cell_header_bytes) return error.InvalidPayload;
            const candidate = payload[offset + 1 .. offset + text_v1.cell_header_bytes];
            if (run_cells != 0 and !std.mem.eql(u8, attributes, candidate)) break;
            const cell_bytes = try textCellRecordBytes(payload[offset..]);
            if (cell_bytes > payload.len - offset) return error.InvalidPayload;
            run_scalars = std.math.add(
                usize,
                run_scalars,
                1 + cell_bytes - text_v1.cell_header_bytes,
            ) catch return error.SnapshotTooLarge;
            offset += cell_bytes;
            column += 1;
            run_cells += 1;
        }
        std.debug.assert(run_cells != 0);
        run_count += 1;
        if (run_count > std.math.maxInt(u16)) return error.SnapshotTooLarge;
        packed_size = std.math.add(
            usize,
            packed_size,
            text_pack_v1.run_length_bytes + text_pack_v1.cell_attribute_bytes + run_scalars,
        ) catch return error.SnapshotTooLarge;
    }
    if (offset != payload.len) return error.InvalidPayload;
    return packed_size;
}

/// Packs one complete frozen `text_v1` body without changing its semantics.
/// Rows use consecutive exact attribute runs only when that representation is
/// smaller; otherwise the original row payload is carried verbatim.
pub fn packTextV1(
    allocator: std.mem.Allocator,
    input: []const u8,
    output: *std.ArrayList(u8),
) TextPackError!void {
    if (input.len == 0 or input.len > maximum_text_snapshot_bytes)
        return error.SnapshotTooLarge;
    output.clearRetainingCapacity();
    errdefer output.clearRetainingCapacity();

    var offset: usize = 0;
    while (offset < input.len) {
        if (input.len - offset < text_v1.record_header_bytes) return error.InvalidPayload;
        const record_header_bytes = input[offset..][0..text_v1.record_header_bytes];
        var encoded_header: [text_v1.record_header_bytes]u8 = undefined;
        @memcpy(&encoded_header, record_header_bytes);
        const header = try decodeTextRecordHeader(&encoded_header);
        const record_len = std.math.add(
            usize,
            text_v1.record_header_bytes,
            header.payload_len,
        ) catch return error.InvalidPayload;
        if (record_len > input.len - offset) return error.InvalidPayload;
        const payload = input[offset + text_v1.record_header_bytes .. offset + record_len];
        try output.appendSlice(allocator, record_header_bytes);
        switch (header.kind) {
            .presentation, .hyperlink => try output.appendSlice(allocator, payload),
            .row => {
                if (payload.len < text_v1.row_header_bytes) return error.InvalidPayload;
                const run_size = try packedRowRunSize(payload);
                const verbatim_size = std.math.add(
                    usize,
                    text_pack_v1.row_mode_bytes,
                    payload.len,
                ) catch return error.SnapshotTooLarge;
                if (run_size >= verbatim_size) {
                    try output.append(allocator, @backingInt(text_pack_v1.RowMode.verbatim));
                    try output.appendSlice(allocator, payload);
                } else {
                    try output.append(allocator, @backingInt(text_pack_v1.RowMode.runs));
                    try output.appendSlice(allocator, payload[0..text_v1.row_header_bytes]);
                    const run_count_offset = output.items.len;
                    try output.appendNTimes(allocator, 0, text_pack_v1.run_count_bytes);
                    const columns = readU16(payload[2..4]);
                    var run_count: u16 = 0;
                    var column: u16 = 0;
                    var cell_offset: usize = text_v1.row_header_bytes;
                    while (column < columns) {
                        const attributes = payload[cell_offset + 1 .. cell_offset + text_v1.cell_header_bytes];
                        const run_length_offset = output.items.len;
                        try output.appendNTimes(allocator, 0, text_pack_v1.run_length_bytes);
                        try output.appendSlice(allocator, attributes);
                        var run_length: u16 = 0;
                        while (column < columns) {
                            const candidate = payload[cell_offset + 1 .. cell_offset + text_v1.cell_header_bytes];
                            if (run_length != 0 and !std.mem.eql(u8, attributes, candidate)) break;
                            const cell_bytes = try textCellRecordBytes(payload[cell_offset..]);
                            const scalar_bytes = cell_bytes - text_v1.cell_header_bytes;
                            try output.append(allocator, payload[cell_offset]);
                            try output.appendSlice(
                                allocator,
                                payload[cell_offset + text_v1.cell_header_bytes ..][0..scalar_bytes],
                            );
                            cell_offset += cell_bytes;
                            column += 1;
                            run_length += 1;
                        }
                        run_count += 1;
                        writeU16(output.items[run_length_offset..][0..2], run_length);
                    }
                    writeU16(output.items[run_count_offset..][0..2], run_count);
                    if (cell_offset != payload.len) return error.InvalidPayload;
                }
            },
            .row_shift => return error.InvalidPayload,
        }
        if (output.items.len > text_pack_v1.maximum_body_bytes) return error.SnapshotTooLarge;
        offset += record_len;
    }
    if (offset != input.len) return error.InvalidPayload;
}

/// Reconstructs the exact frozen `text_v1` body from `text_pack_v1` carriage.
/// The caller supplies the exact expected original byte count from the transport
/// envelope; hostile input cannot grow beyond that bound.
pub fn unpackTextV1(
    allocator: std.mem.Allocator,
    packed_bytes: []const u8,
    expected_text_bytes: usize,
    output: *std.ArrayList(u8),
) TextPackError!void {
    if (packed_bytes.len == 0 or packed_bytes.len > text_pack_v1.maximum_body_bytes or
        expected_text_bytes == 0 or expected_text_bytes > maximum_text_snapshot_bytes)
        return error.SnapshotTooLarge;
    output.clearRetainingCapacity();
    errdefer output.clearRetainingCapacity();
    try output.ensureTotalCapacity(allocator, expected_text_bytes);

    var offset: usize = 0;
    while (offset < packed_bytes.len) {
        if (packed_bytes.len - offset < text_v1.record_header_bytes) return error.InvalidPayload;
        const record_header_bytes = packed_bytes[offset..][0..text_v1.record_header_bytes];
        var encoded_header: [text_v1.record_header_bytes]u8 = undefined;
        @memcpy(&encoded_header, record_header_bytes);
        const header = try decodeTextRecordHeader(&encoded_header);
        try output.appendSlice(allocator, record_header_bytes);
        offset += text_v1.record_header_bytes;
        switch (header.kind) {
            .presentation, .hyperlink => {
                if (header.payload_len > packed_bytes.len - offset) return error.InvalidPayload;
                try output.appendSlice(allocator, packed_bytes[offset..][0..header.payload_len]);
                offset += header.payload_len;
            },
            .row => {
                if (offset >= packed_bytes.len) return error.InvalidPayload;
                const mode = enumFromInt(text_pack_v1.RowMode, packed_bytes[offset]) orelse
                    return error.InvalidPayload;
                offset += text_pack_v1.row_mode_bytes;
                switch (mode) {
                    .verbatim => {
                        if (header.payload_len > packed_bytes.len - offset) return error.InvalidPayload;
                        try output.appendSlice(allocator, packed_bytes[offset..][0..header.payload_len]);
                        offset += header.payload_len;
                    },
                    .runs => {
                        const output_payload_start = output.items.len;
                        if (packed_bytes.len - offset < text_v1.row_header_bytes + text_pack_v1.run_count_bytes)
                            return error.InvalidPayload;
                        const row_header = packed_bytes[offset..][0..text_v1.row_header_bytes];
                        const columns = readU16(row_header[2..4]);
                        try output.appendSlice(allocator, row_header);
                        offset += text_v1.row_header_bytes;
                        const run_count = readU16(packed_bytes[offset..][0..2]);
                        offset += text_pack_v1.run_count_bytes;
                        if (run_count == 0 and columns != 0) return error.InvalidPayload;
                        var emitted_columns: u16 = 0;
                        var run_index: u16 = 0;
                        while (run_index < run_count) : (run_index += 1) {
                            if (packed_bytes.len - offset < text_pack_v1.run_length_bytes + text_pack_v1.cell_attribute_bytes)
                                return error.InvalidPayload;
                            const run_length = readU16(packed_bytes[offset..][0..2]);
                            offset += text_pack_v1.run_length_bytes;
                            if (run_length == 0 or run_length > columns - emitted_columns)
                                return error.InvalidPayload;
                            const attributes = packed_bytes[offset..][0..text_pack_v1.cell_attribute_bytes];
                            offset += text_pack_v1.cell_attribute_bytes;
                            var run_cell: u16 = 0;
                            while (run_cell < run_length) : (run_cell += 1) {
                                if (offset >= packed_bytes.len) return error.InvalidPayload;
                                const scalar_count = packed_bytes[offset];
                                offset += 1;
                                if (scalar_count > text_v1.maximum_cell_scalars) return error.InvalidPayload;
                                const scalar_bytes = @as(usize, scalar_count) * @sizeOf(u32);
                                if (scalar_bytes > packed_bytes.len - offset) return error.InvalidPayload;
                                try output.append(allocator, scalar_count);
                                try output.appendSlice(allocator, attributes);
                                try output.appendSlice(allocator, packed_bytes[offset..][0..scalar_bytes]);
                                offset += scalar_bytes;
                                emitted_columns += 1;
                            }
                        }
                        if (emitted_columns != columns or
                            output.items.len - output_payload_start != header.payload_len)
                            return error.InvalidPayload;
                    },
                }
            },
            .row_shift => return error.InvalidPayload,
        }
        if (output.items.len > expected_text_bytes) return error.InvalidPayload;
    }
    if (offset != packed_bytes.len or output.items.len != expected_text_bytes)
        return error.InvalidPayload;
}

/// Encodes the explicit framing-v7 delta baseline rotation.
pub fn encodeTextRowShift(
    output: *[text_delta_v2.row_shift_bytes]u8,
    rows_up: u16,
) void {
    writeU16(output, rows_up);
}

/// Decodes the exact two-byte framing-v7 delta baseline rotation.
pub fn decodeTextRowShift(input: []const u8) PayloadError!u16 {
    if (input.len != text_delta_v2.row_shift_bytes) return error.InvalidPayload;
    return readU16(input);
}

/// Encodes one semantic `text_v1` terminal color.
pub fn encodeTextColor(
    output: *[text_v1.color_bytes]u8,
    value: TextColor,
) PayloadError!void {
    switch (value.kind) {
        .default => if (value.value != 0) return error.InvalidPayload,
        .indexed => if (value.value > 255) return error.InvalidPayload,
        .rgb => if (value.value > 0x00ff_ffff) return error.InvalidPayload,
    }
    output[0] = @backingInt(value.kind);
    writeU32(output[1..5], value.value);
}

/// Decodes and validates one semantic `text_v1` terminal color.
pub fn decodeTextColor(input: *const [text_v1.color_bytes]u8) PayloadError!TextColor {
    const value = TextColor{
        .kind = enumFromInt(TextColorKind, input[0]) orelse
            return error.InvalidPayload,
        .value = readU32(input[1..5]),
    };
    var canonical: [text_v1.color_bytes]u8 = undefined;
    try encodeTextColor(&canonical, value);
    return value;
}

/// Encodes the fixed prefix of one snapshot graphics manifest.
pub fn encodeSnapshotGraphicsHeader(
    output: *[graphics_v2.manifest_header_bytes]u8,
    value: SnapshotGraphicsHeader,
) void {
    std.debug.assert(value.image_count <= graphics_v2.maximum_images);
    std.debug.assert(value.placement_count <= graphics_v2.maximum_placements);
    writeU64(output[0..8], value.generation);
    writeU64(output[8..16], value.content_generation);
    std.debug.assert(value.cell_pixel_width != 0 and value.cell_pixel_height != 0);
    writeU32(output[16..20], value.cell_pixel_width);
    writeU32(output[20..24], value.cell_pixel_height);
    writeU16(output[24..26], value.image_count);
    writeU16(output[26..28], value.placement_count);
}

/// Decodes the fixed prefix of one bounded snapshot graphics manifest.
pub fn decodeSnapshotGraphicsHeader(input: []const u8) PayloadError!SnapshotGraphicsHeader {
    if (input.len != graphics_v2.manifest_header_bytes) return error.InvalidPayload;
    const cell_pixel_width = readU32(input[16..20]);
    const cell_pixel_height = readU32(input[20..24]);
    const image_count = readU16(input[24..26]);
    const placement_count = readU16(input[26..28]);
    if (cell_pixel_width == 0 or cell_pixel_height == 0) return error.InvalidPayload;
    if (image_count > graphics_v2.maximum_images or
        placement_count > graphics_v2.maximum_placements)
        return error.InvalidPayload;
    return .{
        .generation = readU64(input[0..8]),
        .content_generation = readU64(input[8..16]),
        .cell_pixel_width = cell_pixel_width,
        .cell_pixel_height = cell_pixel_height,
        .image_count = image_count,
        .placement_count = placement_count,
    };
}

/// Encodes one visible image resource descriptor.
pub fn encodeSnapshotImage(output: *[graphics_v2.image_bytes]u8, value: SnapshotImage) void {
    std.debug.assert(validImageExtent(value.image_id, value.generation, value.width, value.height));
    writeU32(output[0..4], value.image_id);
    writeU64(output[4..12], value.generation);
    writeU32(output[12..16], value.width);
    writeU32(output[16..20], value.height);
}

/// Decodes one visible image resource descriptor.
pub fn decodeSnapshotImage(input: []const u8) PayloadError!SnapshotImage {
    if (input.len != graphics_v2.image_bytes) return error.InvalidPayload;
    const value = SnapshotImage{
        .image_id = readU32(input[0..4]),
        .generation = readU64(input[4..12]),
        .width = readU32(input[12..16]),
        .height = readU32(input[16..20]),
    };
    if (!validImageExtent(value.image_id, value.generation, value.width, value.height))
        return error.InvalidPayload;
    return value;
}

/// Encodes one image placement resolved into the snapshot viewport.
pub fn encodeSnapshotImagePlacement(
    output: *[graphics_v2.placement_bytes]u8,
    value: SnapshotImagePlacement,
) void {
    std.debug.assert(value.image_id != 0 and value.generation != 0);
    std.debug.assert(value.source_width != 0 and value.source_height != 0);
    std.debug.assert(value.pixel_width != 0 and value.pixel_height != 0);
    writeU32(output[0..4], value.image_id);
    writeU64(output[4..12], value.generation);
    writeU16(output[12..14], value.row);
    writeU16(output[14..16], value.column);
    writeU32(output[16..20], value.source_x);
    writeU32(output[20..24], value.source_y);
    writeU32(output[24..28], value.source_width);
    writeU32(output[28..32], value.source_height);
    writeU32(output[32..36], value.cell_x);
    writeU32(output[36..40], value.cell_y);
    writeU32(output[40..44], value.pixel_width);
    writeU32(output[44..48], value.pixel_height);
    writeI32(output[48..52], value.z);
}

/// Decodes one image placement resolved into the snapshot viewport.
pub fn decodeSnapshotImagePlacement(input: []const u8) PayloadError!SnapshotImagePlacement {
    if (input.len != graphics_v2.placement_bytes) return error.InvalidPayload;
    const value = SnapshotImagePlacement{
        .image_id = readU32(input[0..4]),
        .generation = readU64(input[4..12]),
        .row = readU16(input[12..14]),
        .column = readU16(input[14..16]),
        .source_x = readU32(input[16..20]),
        .source_y = readU32(input[20..24]),
        .source_width = readU32(input[24..28]),
        .source_height = readU32(input[28..32]),
        .cell_x = readU32(input[32..36]),
        .cell_y = readU32(input[36..40]),
        .pixel_width = readU32(input[40..44]),
        .pixel_height = readU32(input[44..48]),
        .z = readI32(input[48..52]),
    };
    if (value.image_id == 0 or value.generation == 0 or
        value.source_width == 0 or value.source_height == 0 or
        value.pixel_width == 0 or value.pixel_height == 0)
        return error.InvalidPayload;
    return value;
}

fn validImageExtent(image_id: u32, generation: u64, width: u32, height: u32) bool {
    return image_id != 0 and generation != 0 and width != 0 and height != 0 and
        width <= graphics_v2.maximum_dimension and height <= graphics_v2.maximum_dimension and
        imageByteCount(width, height) != null;
}

fn imageByteCount(width: u32, height: u32) ?u32 {
    const pixels = std.math.mul(u64, width, height) catch return null;
    const bytes = std.math.mul(u64, pixels, 4) catch return null;
    if (bytes == 0 or bytes > graphics_v2.maximum_image_bytes or bytes > std.math.maxInt(u32))
        return null;
    return @intCast(bytes);
}

fn writeU32(output: []u8, value: u32) void {
    std.debug.assert(output.len == 4);
    output[0] = @truncate(value >> 24);
    output[1] = @truncate(value >> 16);
    output[2] = @truncate(value >> 8);
    output[3] = @truncate(value);
}

fn writeI32(output: []u8, value: i32) void {
    writeU32(output, @bitCast(value));
}

fn writeU16(output: []u8, value: u16) void {
    std.debug.assert(output.len == 2);
    output[0] = @truncate(value >> 8);
    output[1] = @truncate(value);
}

fn writeU64(output: []u8, value: u64) void {
    std.debug.assert(output.len == 8);
    var shift: u6 = 56;
    for (output) |*byte| {
        byte.* = @truncate(value >> shift);
        shift -|= 8;
    }
}

fn readU32(input: []const u8) u32 {
    std.debug.assert(input.len == 4);
    return (@as(u32, input[0]) << 24) |
        (@as(u32, input[1]) << 16) |
        (@as(u32, input[2]) << 8) |
        @as(u32, input[3]);
}

fn readI32(input: []const u8) i32 {
    return @bitCast(readU32(input));
}

fn readU16(input: []const u8) u16 {
    std.debug.assert(input.len == 2);
    return (@as(u16, input[0]) << 8) | @as(u16, input[1]);
}

fn readU64(input: []const u8) u64 {
    std.debug.assert(input.len == 8);
    var value: u64 = 0;
    for (input) |byte| value = (value << 8) | @as(u64, byte);
    return value;
}

fn enumFromInt(comptime Enum: type, value: @typeInfo(Enum).@"enum".tag_type) ?Enum {
    const info = @typeInfo(Enum).@"enum";
    inline for (info.field_values) |field_value| {
        if (value == field_value) return @fromBackingInt(@intCast(value));
    }
    return null;
}

test "text_pack_v1 round trips exact text_v1 bytes" {
    const allocator = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);

    var presentation_header: [text_v1.record_header_bytes]u8 = undefined;
    encodeTextRecordHeader(&presentation_header, .{
        .kind = .presentation,
        .payload_len = text_v1.presentation_bytes,
    });
    try body.appendSlice(allocator, &presentation_header);
    try body.appendNTimes(allocator, 0, text_v1.presentation_bytes);

    var row_payload: std.ArrayList(u8) = .empty;
    defer row_payload.deinit(allocator);
    try row_payload.appendSlice(allocator, &.{ 0, 0, 0, 5 });
    var attr_a: [text_pack_v1.cell_attribute_bytes]u8 = @splat(0);
    attr_a[0] = 1; // width
    attr_a[1] = 1; // height
    attr_a[4] = 1; // subscale numerator
    attr_a[5] = 1; // subscale denominator
    var attr_b = attr_a;
    attr_b[14] = 1; // distinct foreground color kind byte

    // A, blank, B share attributes; final two cells use another tuple.
    for ([_]?u32{ 'A', null, 'B' }) |scalar| {
        try row_payload.append(allocator, @intFromBool(scalar != null));
        try row_payload.appendSlice(allocator, &attr_a);
        if (scalar) |value| {
            var encoded: [4]u8 = undefined;
            writeU32(&encoded, value);
            try row_payload.appendSlice(allocator, &encoded);
        }
    }
    for ([_]?u32{ null, 'C' }) |scalar| {
        try row_payload.append(allocator, @intFromBool(scalar != null));
        try row_payload.appendSlice(allocator, &attr_b);
        if (scalar) |value| {
            var encoded: [4]u8 = undefined;
            writeU32(&encoded, value);
            try row_payload.appendSlice(allocator, &encoded);
        }
    }
    var row_header: [text_v1.record_header_bytes]u8 = undefined;
    encodeTextRecordHeader(&row_header, .{ .kind = .row, .payload_len = @intCast(row_payload.items.len) });
    try body.appendSlice(allocator, &row_header);
    try body.appendSlice(allocator, row_payload.items);

    const hyperlink_payload = [_]u8{ 0, 0, 0, 7, 0, 3, 'u', 'r', 'i' };
    var hyperlink_header: [text_v1.record_header_bytes]u8 = undefined;
    encodeTextRecordHeader(&hyperlink_header, .{ .kind = .hyperlink, .payload_len = hyperlink_payload.len });
    try body.appendSlice(allocator, &hyperlink_header);
    try body.appendSlice(allocator, &hyperlink_payload);

    var packed_body: std.ArrayList(u8) = .empty;
    defer packed_body.deinit(allocator);
    try packTextV1(allocator, body.items, &packed_body);
    try std.testing.expect(packed_body.items.len < body.items.len);

    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(allocator);
    try unpackTextV1(allocator, packed_body.items, body.items.len, &decoded);
    try std.testing.expectEqualSlices(u8, body.items, decoded.items);

    // Every strict truncation must fail rather than produce a partial body.
    var truncated: std.ArrayList(u8) = .empty;
    defer truncated.deinit(allocator);
    for (0..packed_body.items.len) |cut| {
        if (unpackTextV1(allocator, packed_body.items[0..cut], body.items.len, &truncated)) |_| {
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "text_pack_v1 falls back to verbatim rows when runs expand" {
    const allocator = std.testing.allocator;
    var row_payload: std.ArrayList(u8) = .empty;
    defer row_payload.deinit(allocator);
    try row_payload.appendSlice(allocator, &.{ 0, 0, 0, 2 });
    var first: [text_pack_v1.cell_attribute_bytes]u8 = @splat(0);
    first[0] = 1;
    var second = first;
    second[1] = 1;
    for ([_][text_pack_v1.cell_attribute_bytes]u8{ first, second }) |attributes| {
        try row_payload.append(allocator, 0);
        try row_payload.appendSlice(allocator, &attributes);
    }
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    var header: [text_v1.record_header_bytes]u8 = undefined;
    encodeTextRecordHeader(&header, .{ .kind = .row, .payload_len = @intCast(row_payload.items.len) });
    try body.appendSlice(allocator, &header);
    try body.appendSlice(allocator, row_payload.items);

    var packed_body: std.ArrayList(u8) = .empty;
    defer packed_body.deinit(allocator);
    try packTextV1(allocator, body.items, &packed_body);
    try std.testing.expectEqual(
        @backingInt(text_pack_v1.RowMode.verbatim),
        packed_body.items[text_v1.record_header_bytes],
    );

    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(allocator);
    try unpackTextV1(allocator, packed_body.items, body.items.len, &decoded);
    try std.testing.expectEqualSlices(u8, body.items, decoded.items);
}

test "text_pack_v1 rejects malformed cell scalar counts" {
    const allocator = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    var header: [text_v1.record_header_bytes]u8 = undefined;
    const payload_len = text_v1.row_header_bytes + text_v1.cell_header_bytes;
    encodeTextRecordHeader(&header, .{ .kind = .row, .payload_len = payload_len });
    try body.appendSlice(allocator, &header);
    try body.appendSlice(allocator, &.{ 0, 0, 0, 1 });
    try body.append(allocator, text_v1.maximum_cell_scalars + 1);
    try body.appendNTimes(allocator, 0, text_pack_v1.cell_attribute_bytes);
    var packed_body: std.ArrayList(u8) = .empty;
    defer packed_body.deinit(allocator);
    try std.testing.expectError(error.InvalidPayload, packTextV1(allocator, body.items, &packed_body));
}

test "text_v1 record and color grammar is exact and hostile-safe" {
    var record: [text_v1.record_header_bytes]u8 = undefined;
    encodeTextRecordHeader(&record, .{ .kind = .row, .payload_len = 0x0102_0304 });
    try std.testing.expectEqualSlices(u8, &.{
        0x02, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04,
    }, &record);
    const decoded_record = try decodeTextRecordHeader(&record);
    try std.testing.expectEqual(TextRecordKind.row, decoded_record.kind);
    try std.testing.expectEqual(@as(u32, 0x0102_0304), decoded_record.payload_len);
    var bad_record = record;
    bad_record[2] = 1;
    try std.testing.expectError(error.InvalidPayload, decodeTextRecordHeader(&bad_record));
    bad_record = record;
    bad_record[0] = 0xff;
    try std.testing.expectError(error.InvalidPayload, decodeTextRecordHeader(&bad_record));

    var shift: [text_delta_v2.row_shift_bytes]u8 = undefined;
    encodeTextRowShift(&shift, 0x1234);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34 }, &shift);
    try std.testing.expectEqual(@as(u16, 0x1234), try decodeTextRowShift(&shift));
    try std.testing.expectError(error.InvalidPayload, decodeTextRowShift(shift[0..1]));

    var color: [text_v1.color_bytes]u8 = undefined;
    try encodeTextColor(&color, .{ .kind = .rgb, .value = 0x00ab_cdef });
    try std.testing.expectEqualSlices(u8, &.{ 2, 0, 0xab, 0xcd, 0xef }, &color);
    try std.testing.expectEqualDeep(
        TextColor{ .kind = .rgb, .value = 0x00ab_cdef },
        try decodeTextColor(&color),
    );
    try std.testing.expectError(
        error.InvalidPayload,
        encodeTextColor(&color, .{ .kind = .default, .value = 1 }),
    );
    try std.testing.expectError(
        error.InvalidPayload,
        encodeTextColor(&color, .{ .kind = .indexed, .value = 256 }),
    );
    color = .{ 2, 1, 0, 0, 0 };
    try std.testing.expectError(error.InvalidPayload, decodeTextColor(&color));
}

test {
    std.testing.refAllDecls(properties);
}
