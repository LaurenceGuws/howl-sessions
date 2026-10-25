//! Public caller-storage byte-client proofs without any native connection owner.
const std = @import("std");
const byte = @import("server_client_byte");
const server = @import("server_protocol");
const p = byte.protocol;
const Fixture = struct {
    storage: byte.Storage,
    packet: [128]u8,
    output: [128]u8,
    observation: [1024]u8,
    result: [32]u8,

    fn init(self: *Fixture) byte.Error!*byte.ByteClient {
        return byte.ByteClient.init(&self.storage, .{
            .packet = &self.packet,
            .outgoing = &self.output,
            .observation = &self.observation,
            .result = &self.result,
        });
    }
};
fn readyBytes(output: *[52]u8) ![]const u8 {
    return std.fmt.hexToBytes(output, "53525652020c000000000028000000000000005b000000000000000700000000000000030000000000000002000000000000002a");
}
fn frame(output: []u8, kind: p.Kind, payload: []const u8) ![]const u8 {
    try std.testing.expect(output.len >= p.header_bytes + payload.len);
    try p.encodeHeader(output[0..p.header_bytes], .{ .kind = kind, .payload_len = @intCast(payload.len) });
    @memcpy(output[p.header_bytes..][0..payload.len], payload);
    return output[0 .. p.header_bytes + payload.len];
}
fn attach(client: *byte.ByteClient) !void {
    client.resetAwaitReady();
    var buffer: [52]u8 = undefined;
    const received = try client.feed(try readyBytes(&buffer));
    try std.testing.expect(received.event == .attached);
    try std.testing.expectEqual(@as(u64, 42), received.event.attached.client_id);
}

test "opaque aligned caller storage rejects overlap and preserves buffers" {
    try std.testing.expect(@typeInfo(byte.ByteClient) == .@"opaque");
    var f: Fixture = undefined;
    @memset(&f.output, 0xa5);
    @memset(&f.result, 0xb6);
    const client = try f.init();
    try std.testing.expect(!client.isIdle());
    try std.testing.expect(client.identity() == null);
    try std.testing.expect(std.mem.allEqual(u8, &f.output, 0xa5));
    try std.testing.expect(std.mem.allEqual(u8, &f.result, 0xb6));
    try std.testing.expectError(error.InvalidBuffers, byte.ByteClient.init(&f.storage, .{
        .packet = &f.packet,
        .outgoing = &f.packet,
        .observation = &f.observation,
        .result = &f.result,
    }));
    try std.testing.expectError(error.InvalidBuffers, byte.ByteClient.init(&f.storage, .{
        .packet = &f.packet,
        .outgoing = &f.output,
        .observation = &f.observation,
        .result = f.storage.bytes[0..4],
    }));
    try std.testing.expectError(error.InvalidBuffers, byte.ByteClient.init(&f.storage, .{
        .packet = f.packet[0 .. p.header_bytes - 1],
        .outgoing = &f.output,
        .observation = &f.observation,
        .result = &f.result,
    }));
}

test "every ready split preserves exact identity and duplicate ready retires" {
    var f: Fixture = undefined;
    const client = try f.init();
    var buffer: [52]u8 = undefined;
    const bytes = try readyBytes(&buffer);
    for (0..bytes.len + 1) |split| {
        client.resetAwaitReady();
        const first = try client.feed(bytes[0..split]);
        const second = try client.feed(bytes[split..]);
        try std.testing.expectEqual(split, first.consumed);
        try std.testing.expectEqual(bytes.len - split, second.consumed);
        try std.testing.expect(client.isIdle());
        try std.testing.expectEqual(@as(u64, 91), client.identity().?.server_id);
        try std.testing.expectEqual(@as(u64, 42), client.identity().?.client_id);
    }
    try std.testing.expectError(error.UnknownKind, client.feed(bytes));
    try std.testing.expect(!client.isIdle());
    try std.testing.expectEqual(@as(usize, 0), client.outgoing().len);
    try std.testing.expectError(error.InvalidState, client.sendBytes(.bytes, "x"));
}

test "invalid starts aliases and insufficient output do not mutate state or bytes" {
    var f: Fixture = undefined;
    const client = try f.init();
    try attach(client);
    @memset(&f.output, 0x6d);
    @memset(&f.result, 0x4c);
    try std.testing.expectError(error.InvalidPayload, client.sendKey(.{ .kind = .named, .key_value = 0, .action = .press }));
    try std.testing.expectError(error.InvalidPayload, client.requestImage(.{ .image_id = 0, .generation = 9 }));
    try std.testing.expectError(error.InvalidPayload, client.sendBytes(.bytes, ""));
    try std.testing.expectError(error.InvalidInputAlias, client.sendBytes(.paste, f.output[0..2]));
    try std.testing.expectError(error.InvalidInputAlias, client.feed(f.packet[0..2]));
    const oversized: [128]u8 = @splat(0xaa);
    try std.testing.expectError(error.BufferTooSmall, client.sendBytes(.paste, &oversized));
    try std.testing.expect(client.isIdle());
    try std.testing.expect(std.mem.allEqual(u8, &f.output, 0x6d));
    try std.testing.expect(std.mem.allEqual(u8, &f.result, 0x4c));
}

test "caller capacity is independent of browser four KiB admission" {
    var f: Fixture = undefined;
    var outgoing: [5020]u8 = undefined;
    const body: [5000]u8 = @splat(0x78);
    const client = try byte.ByteClient.init(&f.storage, .{
        .packet = &f.packet,
        .outgoing = &outgoing,
        .observation = &f.observation,
        .result = &f.result,
    });
    try attach(client);
    try client.sendBytes(.paste, &body);
    try std.testing.expectEqual(@as(usize, 5013), client.outgoing().len);
    try std.testing.expectEqualSlices(u8, &body, client.outgoing()[13..]);
}

test "complete rejection permits reuse while result correlation failure retires" {
    var f: Fixture = undefined;
    const client = try f.init();
    try attach(client);
    try client.sendBytes(.bytes, "x");
    var response: [32]u8 = undefined;
    var payload: [p.payload_bytes.result]u8 = undefined;
    p.encodeResult(&payload, .{ .request_kind = .input, .code = .not_leader });
    const rejected = try client.feed(try frame(&response, .result, &payload));
    try std.testing.expect(rejected.event == .result);
    try std.testing.expectEqual(p.ResultCode.not_leader, rejected.event.result.code);
    try std.testing.expect(client.isIdle());
    try client.sendFocus(.in);
    p.encodeResult(&payload, .{ .request_kind = .resize, .code = .ok });
    try std.testing.expectError(error.InputRejected, client.feed(try frame(&response, .result, &payload)));
    try std.testing.expect(!client.isIdle());
    try std.testing.expectEqual(@as(usize, 0), client.outgoing().len);
}

test "claim resize stops at outgoing followup with exact unconsumed suffix" {
    var f: Fixture = undefined;
    const client = try f.init();
    try attach(client);
    try client.resize(.{ .rows = 2, .columns = 3 }, true);
    try std.testing.expectEqual(@as(u8, @backingInt(p.Kind.assign_leader)), client.outgoing()[5]);
    var replies: [28]u8 = undefined;
    var payload: [p.payload_bytes.result]u8 = undefined;
    p.encodeResult(&payload, .{ .request_kind = .assign_leader, .code = .ok });
    const first_frame = try frame(replies[0..14], .result, &payload);
    p.encodeResult(&payload, .{ .request_kind = .resize, .code = .not_leader });
    const second_frame = try frame(replies[14..], .result, &payload);
    const first = try client.feed(&replies);
    try std.testing.expectEqual(first_frame.len, first.consumed);
    try std.testing.expect(first.event == .outgoing_followup);
    try std.testing.expectEqual(@as(u8, @backingInt(p.Kind.resize)), client.outgoing()[5]);
    try std.testing.expectEqual(@as(u8, 2), client.outgoing()[13]);
    try std.testing.expectEqual(@as(u8, 3), client.outgoing()[15]);
    const second = try client.feed(second_frame);
    try std.testing.expect(second.event == .result);
    try std.testing.expectEqual(p.ResultCode.not_leader, second.event.result.code);
    try std.testing.expect(client.isIdle());
}

test "selected result is independent of receive bytes and capacity failure writes nothing" {
    var f: Fixture = undefined;
    const client = try f.init();
    try attach(client);
    const selection = p.TextExtract{ .start = .{ .row = 0, .column = 0 }, .end = .{ .row = 0, .column = 1 }, .columns = 2, .alternate_screen = false };
    try client.textExtract(selection);
    var response: [128]u8 = undefined;
    const result = try client.feed(try frame(&response, .text_extract_data, "A\xcc\x81"));
    try std.testing.expect(result.event == .text);
    @memset(&response, 0x6d);
    try std.testing.expectEqualStrings("A\xcc\x81", result.event.text);
    try client.textExtract(selection);
    @memset(&f.result, 0xa5);
    const too_large: [33]u8 = @splat(0x78);
    try std.testing.expectError(error.ResultTooSmall, client.feed(try frame(&response, .text_extract_data, &too_large)));
    try std.testing.expect(std.mem.allEqual(u8, &f.result, 0xa5));
    try expectRetired(client);
}

test "image chunks publish only complete exact image and release gates new requests" {
    var f: Fixture = undefined;
    const client = try f.init();
    try attach(client);
    try client.requestImage(.{ .image_id = 7, .generation = 9 });
    var response: [128]u8 = undefined;
    var begin: [p.payload_bytes.image_begin]u8 = undefined;
    p.encodeImageBegin(&begin, .{ .image_id = 7, .generation = 9, .width = 1, .height = 1, .byte_count = 4 });
    const started = try client.feed(try frame(&response, .image_begin, &begin));
    try std.testing.expect(started.event == .progress);
    const pixel = [_]u8{ 1, 2, 3, 4 };
    for (pixel) |channel| {
        const staged = try client.feed(try frame(&response, .image_data, &.{channel}));
        try std.testing.expect(staged.event == .progress);
    }
    var end: [p.payload_bytes.image_end]u8 = undefined;
    p.encodeImageEnd(&end, .{ .image_id = 7, .generation = 9 });
    const complete = try client.feed(try frame(&response, .image_end, &end));
    try std.testing.expect(complete.event == .image);
    @memset(&response, 0x6d);
    try std.testing.expectEqualSlices(u8, &pixel, complete.event.image.bytes);
    try std.testing.expectError(error.InvalidState, client.sendBytes(.bytes, "x"));
    try client.releaseImage();
    try std.testing.expect(client.isIdle());
    try std.testing.expectEqual(@as(usize, 0), client.image().bytes.len);
}

test "wrong image identity zero chunks overflow and unfinished image retire" {
    var f: Fixture = undefined;
    const client = try f.init();
    var response: [128]u8 = undefined;
    var begin: [p.payload_bytes.image_begin]u8 = undefined;
    for (0..4) |scenario| {
        try attach(client);
        try client.requestImage(.{ .image_id = 7, .generation = 9 });
        p.encodeImageBegin(&begin, .{ .image_id = if (scenario == 0) 8 else 7, .generation = 9, .width = 1, .height = 1, .byte_count = 4 });
        const framed = try frame(&response, .image_begin, &begin);
        if (scenario == 0) {
            try std.testing.expectError(error.ImageIdentityMismatch, client.feed(framed));
        } else {
            const started = try client.feed(framed);
            try std.testing.expect(started.event == .progress);
            if (scenario == 1) {
                try std.testing.expectError(error.InvalidImageData, client.feed(try frame(&response, .image_data, "")));
            } else if (scenario == 2) {
                try std.testing.expectError(error.InvalidImageData, client.feed(try frame(&response, .image_data, "12345")));
            } else try std.testing.expectError(error.TruncatedResponse, client.finish());
        }
        try std.testing.expect(!client.isIdle());
        try std.testing.expectEqual(@as(usize, 0), client.outgoing().len);
    }
}

test "packet capacity and partial EOF fail boundedly and reset restores ready" {
    var f: Fixture = undefined;
    const client = try f.init();
    client.resetAwaitReady();
    var header: [p.header_bytes]u8 = undefined;
    try server.encodeHeader(&header, .{ .kind = .attach_ready, .payload_len = 117 });
    try std.testing.expectError(error.BufferTooSmall, client.feed(&header));
    client.resetAwaitReady();
    var ready: [52]u8 = undefined;
    const bytes = try readyBytes(&ready);
    const partial = try client.feed(bytes[0..17]);
    try std.testing.expect(partial.event == .progress);
    try std.testing.expectError(error.TruncatedResponse, client.finish());
    try attach(client);
    try client.finish();
    try std.testing.expectError(error.InvalidState, client.feed(bytes));
}

fn expectRetired(client: *byte.ByteClient) !void {
    try std.testing.expect(!client.isIdle());
    try std.testing.expectEqual(@as(usize, 0), client.outgoing().len);
    try std.testing.expectError(error.InvalidState, client.feed(&.{}));
}

test "result capacity is distinct from malformed text and mismatched image identity" {
    const Case = enum { image_capacity, image_identity, text_utf8 };
    for ([_]Case{ .image_capacity, .image_identity, .text_utf8 }) |case| {
        var f: Fixture = undefined;
        @memset(&f.result, 0xa5);
        const client = try f.init();
        try attach(client);
        var response: [128]u8 = undefined;
        var length: usize = 0;
        if (case == .text_utf8) {
            try client.textExtract(.{ .start = .{ .row = 0, .column = 0 }, .end = .{ .row = 0, .column = 1 }, .columns = 2, .alternate_screen = false });
            const invalid: [33]u8 = @splat(0xff);
            length = (try frame(&response, .text_extract_data, &invalid)).len;
        } else {
            try client.requestImage(.{ .image_id = 7, .generation = 9 });
            var begin: [p.payload_bytes.image_begin]u8 = undefined;
            p.encodeImageBegin(&begin, .{ .image_id = if (case == .image_identity) 8 else 7, .generation = 9, .width = 3, .height = 3, .byte_count = 36 });
            length = (try frame(&response, .image_begin, &begin)).len;
        }
        const expected: byte.Error = switch (case) {
            .image_capacity => error.ResultTooSmall,
            .image_identity => error.ImageIdentityMismatch,
            .text_utf8 => error.InvalidTextExtractData,
        };
        try std.testing.expectError(expected, client.feed(response[0..length]));
        try std.testing.expect(std.mem.allEqual(u8, &f.result, 0xa5));
        try expectRetired(client);
    }
}

test "complete interaction image selection and geometry rejections remain reusable" {
    var f: Fixture = undefined;
    const client = try f.init();
    try attach(client);
    for ([_]p.Kind{ .interaction_state, .image_request, .text_extract, .assign_leader, .resize }) |kind| {
        switch (kind) {
            .interaction_state => try client.interactionState(),
            .image_request => try client.requestImage(.{ .image_id = 7, .generation = 9 }),
            .text_extract => try client.textExtract(.{ .start = .{ .row = 0, .column = 0 }, .end = .{ .row = 0, .column = 1 }, .columns = 2, .alternate_screen = false }),
            .assign_leader, .resize => try client.resize(.{ .rows = 2, .columns = 3 }, kind == .assign_leader),
            else => return error.InvalidTestCase,
        }
        var response: [32]u8 = undefined;
        var payload: [p.payload_bytes.result]u8 = undefined;
        p.encodeResult(&payload, .{ .request_kind = kind, .code = .not_leader });
        const rejected = try client.feed(try frame(&response, .result, &payload));
        try std.testing.expect(rejected.event == .result);
        try std.testing.expectEqual(kind, rejected.event.result.request_kind);
        try std.testing.expectEqual(p.ResultCode.not_leader, rejected.event.result.code);
        try std.testing.expect(client.isIdle());
        try client.sendFocus(.in);
        p.encodeResult(&payload, .{ .request_kind = .input, .code = .ok });
        const accepted = try client.feed(try frame(&response, .result, &payload));
        try std.testing.expect(accepted.event == .result);
        try std.testing.expectEqual(p.ResultCode.ok, accepted.event.result.code);
        try std.testing.expect(client.isIdle());
    }
}

test "collected observation stops at completion enforces caller capacity and resets partial state" {
    var response: [96]u8 = undefined;
    var length = (try frame(&response, .snapshot_begin, &.{})).len;
    length += (try frame(response[length..], .snapshot_raw_data, "v")).len;
    length += (try frame(response[length..], .snapshot_end, &.{})).len;
    const observation_len = length;
    var result: [p.payload_bytes.result]u8 = undefined;
    p.encodeResult(&result, .{ .request_kind = .input, .code = .ok });
    length += (try frame(response[length..], .result, &result)).len;
    var f: Fixture = undefined;
    const client = try f.init();
    try attach(client);
    try client.observe(.{ .after_revision = 0, .history_offset = 0 }, .collect);
    const complete = try client.feed(response[0..length]);
    try std.testing.expectEqual(observation_len, complete.consumed);
    try std.testing.expect(complete.event == .observation);
    // Intentionally invalid VT payloads remain for the caller's semantic decoder.
    try std.testing.expect(complete.event.observation == null);
    try std.testing.expectEqualSlices(u8, response[0..observation_len], client.observationBytes());
    try client.sendFocus(.in);
    const following = try client.feed(response[complete.consumed..length]);
    try std.testing.expect(following.event == .result);
    try std.testing.expect(client.isIdle());

    try client.observe(.{ .after_revision = 0, .history_offset = 0 }, .collect);
    const partial = try client.feed(response[0..5]);
    try std.testing.expect(partial.event == .progress);
    try attach(client);
    try std.testing.expectEqual(@as(usize, 0), client.observationBytes().len);
    try client.observe(.{ .after_revision = 0, .history_offset = 0 }, .collect);
    try std.testing.expect((try client.feed(response[0..observation_len])).event == .observation);

    var small: Fixture = undefined;
    @memset(&small.observation, 0xa5);
    const bounded = try byte.ByteClient.init(&small.storage, .{
        .packet = &small.packet,
        .outgoing = &small.output,
        .observation = small.observation[0 .. observation_len - 1],
        .result = &small.result,
    });
    try attach(bounded);
    try bounded.observe(.{ .after_revision = 0, .history_offset = 0 }, .collect);
    try std.testing.expectError(error.SnapshotTooLarge, bounded.feed(response[0..observation_len]));
    try std.testing.expect(std.mem.allEqual(u8, small.observation[observation_len - 1 ..], 0xa5));
    try expectRetired(bounded);
}

test "live observation validates envelope revision and history without decoding VT bodies" {
    const Case = enum { valid, revision, history, missing_body, mixed_body, order };
    for ([_]Case{ .valid, .revision, .history, .missing_body, .mixed_body, .order }) |case| {
        var f: Fixture = undefined;
        const client = try f.init();
        try attach(client);
        try client.observe(.{ .after_revision = 0, .history_offset = 0 }, .live);
        var response: [128]u8 = undefined;
        var begin: [p.payload_bytes.snapshot_begin]u8 = undefined;
        p.encodeSnapshotBegin(&begin, .{
            .revision = 17,
            .terminal = .{ .revision = 9, .history_offset = if (case == .history) 1 else 0, .history_count = 1, .history_row_base = 0, .rows = 2, .columns = 3, .cursor_row = 0, .cursor_column = 0, .cursor_shape = 0, .cursor_visible = true, .cursor_blink = false, .alternate_screen = false },
            .stream_closed = false,
            .child_exited = false,
            .leader_present = false,
            .you_are_leader = false,
        });
        try std.testing.expect((try client.feed(try frame(&response, .snapshot_begin, &begin))).event == .progress);
        if (case == .missing_body) {
            try std.testing.expectError(error.MissingSnapshotBody, client.feed(try frame(&response, .snapshot_graphics, &.{})));
            try expectRetired(client);
            continue;
        }
        try std.testing.expect((try client.feed(try frame(&response, .snapshot_raw_data, "v"))).event == .progress);
        if (case == .mixed_body) {
            try std.testing.expectError(error.MixedSnapshotBodyEncoding, client.feed(try frame(&response, .snapshot_data, "v")));
            try expectRetired(client);
            continue;
        }
        if (case == .order) {
            try std.testing.expectError(error.UnexpectedSnapshotFrame, client.feed(try frame(&response, .snapshot_properties, &.{})));
            try expectRetired(client);
            continue;
        }
        try std.testing.expect((try client.feed(try frame(&response, .snapshot_graphics, &.{}))).event == .progress);
        try std.testing.expect((try client.feed(try frame(&response, .snapshot_properties, &.{}))).event == .progress);
        var end: [p.payload_bytes.snapshot_end]u8 = undefined;
        p.encodeSnapshotEnd(&end, .{ .revision = if (case == .revision) 18 else 17 });
        const bytes = try frame(&response, .snapshot_end, &end);
        if (case == .revision or case == .history) {
            try std.testing.expectError(if (case == .revision) error.SnapshotRevisionMismatch else error.LiveHistoryOffsetMismatch, client.feed(bytes));
            try expectRetired(client);
        } else {
            const complete = try client.feed(bytes);
            try std.testing.expect(complete.event == .observation);
            try std.testing.expectEqual(@as(u64, 17), complete.event.observation.?.revision);
            try std.testing.expect(client.isIdle());
        }
    }
}

fn completeImage(client: *byte.ByteClient, image_id: u32, generation: u64, pixel: [4]u8) !byte.Image {
    var response: [128]u8 = undefined;
    var begin: [p.payload_bytes.image_begin]u8 = undefined;
    p.encodeImageBegin(&begin, .{ .image_id = image_id, .generation = generation, .width = 1, .height = 1, .byte_count = 4 });
    try std.testing.expect((try client.feed(try frame(&response, .image_begin, &begin))).event == .progress);
    try std.testing.expect((try client.feed(try frame(&response, .image_data, &pixel))).event == .progress);
    var end: [p.payload_bytes.image_end]u8 = undefined;
    p.encodeImageEnd(&end, .{ .image_id = image_id, .generation = generation });
    const complete = try client.feed(try frame(&response, .image_end, &end));
    try std.testing.expect(complete.event == .image);
    return complete.event.image;
}

test "held image permits explicit replacement and survives clean finish in caller storage" {
    var f: Fixture = undefined;
    const client = try f.init();
    try attach(client);
    try client.requestImage(.{ .image_id = 7, .generation = 9 });
    const first = try completeImage(client, 7, 9, .{ 1, 2, 3, 4 });
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, first.bytes);
    try client.requestImage(.{ .image_id = 7, .generation = 10 });
    try std.testing.expectEqual(@as(usize, 0), client.image().bytes.len);
    const replacement = try completeImage(client, 7, 10, .{ 4, 3, 2, 1 });
    try std.testing.expectEqual(@as(u64, 10), replacement.generation);
    try client.finish();
    try std.testing.expectEqual(@as(usize, 0), client.outgoing().len);
    try std.testing.expectEqualSlices(u8, &.{ 4, 3, 2, 1 }, replacement.bytes);
    try std.testing.expectEqual(@as(u64, 10), client.image().generation);
    try std.testing.expectError(error.InvalidState, client.feed(&.{}));
    client.resetAwaitReady();
    try std.testing.expectEqual(@as(usize, 0), client.image().bytes.len);
    try std.testing.expect(client.identity() == null);
}
