//! Demand-driven exact terminal image resource client.
//!
//! Rich snapshots carry only visible image identities and placements. This
//! module fetches one exact RGBA8 image generation on a caller-owned connection;
//! it owns no terminal state, renderer resource cache, or residency policy.

const std = @import("std");
const protocol = @import("server_protocol").terminal;
const client = @import("terminal_owner");

/// Reports transport, framing, allocation, and exact-resource validation failures.
pub const Error = client.Error || std.mem.Allocator.Error || protocol.PayloadError || error{
    UnexpectedFrame,
    ServerRejected,
    InvalidResource,
};

/// Owns one exact decoded RGBA8 terminal-image generation.
pub const Resource = struct {
    allocator: std.mem.Allocator,
    image_id: u32,
    generation: u64,
    width: u32,
    height: u32,
    pixels: []u8,

    /// Releases this resource's owned pixel buffer.
    pub fn deinit(self: *Resource) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }
};

/// Fetches one exact image generation named by a rich snapshot manifest.
/// After sending, any failure except ServerRejected requires retiring the
/// connection: an unread or partially consumed frame is not safely resumable.
pub fn request(
    connection: *client.Connection,
    allocator: std.mem.Allocator,
    image_id: u32,
    generation: u64,
) Error!Resource {
    if (image_id == 0 or generation == 0) return error.InvalidResource;
    var payload: [protocol.payload_bytes.image_request]u8 = undefined;
    protocol.encodeImageRequest(&payload, .{ .image_id = image_id, .generation = generation });
    try connection.send(.image_request, &payload);
    return receiveFrom(connection, allocator, image_id, generation) catch |err| {
        if (err != error.ServerRejected) client.retire(connection);
        return err;
    };
}

fn receiveFrom(
    // zig-audit: acknowledge anytype
    // reason: The receiver is shared by the real Connection and a narrow deterministic framing fixture with receive/receiveInto.
    connection: anytype,
    allocator: std.mem.Allocator,
    image_id: u32,
    generation: u64,
) Error!Resource {
    var begin_frame = try connection.receive();
    defer begin_frame.deinit();
    if (begin_frame.kind == .result) {
        const result = try protocol.decodeResult(begin_frame.payload);
        if (result.request_kind != .image_request or result.code == .ok)
            return error.UnexpectedFrame;
        if (result.code == .rejected) return error.ServerRejected;
        return error.UnexpectedFrame;
    }
    if (begin_frame.kind != .image_begin) return error.UnexpectedFrame;
    const begin = try protocol.decodeImageBegin(begin_frame.payload);
    if (begin.image_id != image_id or begin.generation != generation)
        return error.InvalidResource;

    const pixels = try allocator.alloc(u8, begin.byte_count);
    errdefer allocator.free(pixels);
    var offset: usize = 0;
    while (offset < pixels.len) {
        const capacity = @min(pixels.len - offset, protocol.image_data_chunk_bytes);
        const count = connection.receiveInto(.image_data, pixels[offset..][0..capacity]) catch |failure| {
            // Preserve the image receiver's existing semantic error vocabulary.
            // Framing and transport failures propagate unchanged.
            return if (failure == error.InvalidPayload) error.InvalidResource else failure;
        };
        offset += count;
    }

    var end_frame = try connection.receive();
    defer end_frame.deinit();
    if (end_frame.kind != .image_end) return error.UnexpectedFrame;
    const end = try protocol.decodeImageEnd(end_frame.payload);
    if (end.image_id != image_id or end.generation != generation)
        return error.InvalidResource;
    return .{
        .allocator = allocator,
        .image_id = image_id,
        .generation = generation,
        .width = begin.width,
        .height = begin.height,
        .pixels = pixels,
    };
}

const TestFrame = struct {
    kind: protocol.Kind,
    payload: []const u8,

    fn deinit(self: *TestFrame) void {
        self.* = undefined;
    }
};

const TestFrames = struct {
    frames: []const TestFrame,
    index: usize = 0,

    fn receiveInto(self: *TestFrames, expected_kind: protocol.Kind, destination: []u8) Error!usize {
        const frame = try self.receive();
        if (frame.kind != expected_kind or frame.payload.len == 0 or frame.payload.len > destination.len)
            return error.InvalidPayload;
        @memcpy(destination[0..frame.payload.len], frame.payload);
        return frame.payload.len;
    }

    fn receive(self: *TestFrames) Error!TestFrame {
        if (self.index >= self.frames.len) return error.UnexpectedFrame;
        defer self.index += 1;
        return self.frames[self.index];
    }
};

test "exact image resource receiver owns complete bounded RGBA bytes" {
    var begin: [protocol.payload_bytes.image_begin]u8 = undefined;
    protocol.encodeImageBegin(&begin, .{
        .image_id = 7,
        .generation = 9,
        .width = 2,
        .height = 2,
        .byte_count = 16,
    });
    var end: [protocol.payload_bytes.image_end]u8 = undefined;
    protocol.encodeImageEnd(&end, .{ .image_id = 7, .generation = 9 });
    const first = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const second = [_]u8{ 9, 10, 11, 12, 13, 14, 15, 16 };
    const frames = [_]TestFrame{
        .{ .kind = .image_begin, .payload = &begin },
        .{ .kind = .image_data, .payload = &first },
        .{ .kind = .image_data, .payload = &second },
        .{ .kind = .image_end, .payload = &end },
    };
    var reader = TestFrames{ .frames = &frames };
    var resource = try receiveFrom(&reader, std.testing.allocator, 7, 9);
    defer resource.deinit();
    try std.testing.expectEqual(@as(u32, 2), resource.width);
    try std.testing.expectEqual(@as(u32, 2), resource.height);
    try std.testing.expectEqualSlices(u8, &.{
        1, 2,  3,  4,  5,  6,  7,  8,
        9, 10, 11, 12, 13, 14, 15, 16,
    }, resource.pixels);
}

test "image resource receiver rejects stale and incomplete identities" {
    var begin: [protocol.payload_bytes.image_begin]u8 = undefined;
    protocol.encodeImageBegin(&begin, .{
        .image_id = 7,
        .generation = 10,
        .width = 1,
        .height = 1,
        .byte_count = 4,
    });
    const bad = [_]TestFrame{.{ .kind = .image_begin, .payload = &begin }};
    var stale = TestFrames{ .frames = &bad };
    try std.testing.expectError(
        error.InvalidResource,
        receiveFrom(&stale, std.testing.allocator, 7, 9),
    );

    var result: [protocol.payload_bytes.result]u8 = undefined;
    protocol.encodeResult(&result, .{ .request_kind = .image_request, .code = .rejected });
    const rejected = [_]TestFrame{.{ .kind = .result, .payload = &result }};
    var server = TestFrames{ .frames = &rejected };
    try std.testing.expectError(
        error.ServerRejected,
        receiveFrom(&server, std.testing.allocator, 7, 9),
    );

    protocol.encodeResult(&result, .{ .request_kind = .image_request, .code = .unsupported });
    const unsupported = [_]TestFrame{.{ .kind = .result, .payload = &result }};
    var incompatible = TestFrames{ .frames = &unsupported };
    try std.testing.expectError(
        error.UnexpectedFrame,
        receiveFrom(&incompatible, std.testing.allocator, 7, 9),
    );
}

test "image data semantic failures retain InvalidResource and release pixels" {
    var begin: [protocol.payload_bytes.image_begin]u8 = undefined;
    protocol.encodeImageBegin(&begin, .{ .image_id = 7, .generation = 9, .width = 2, .height = 2, .byte_count = 16 });
    const data: [17]u8 = @splat(0xa5);
    for ([_]TestFrame{
        .{ .kind = .image_end, .payload = data[0..4] },
        .{ .kind = .image_data, .payload = data[0..0] },
        .{ .kind = .image_data, .payload = &data },
    }) |bad| {
        const frames = [_]TestFrame{ .{ .kind = .image_begin, .payload = &begin }, bad };
        var reader = TestFrames{ .frames = &frames };
        try std.testing.expectError(error.InvalidResource, receiveFrom(&reader, std.testing.allocator, 7, 9));
    }
    protocol.encodeImageBegin(&begin, .{ .image_id = 7, .generation = 9, .width = 512, .height = 256, .byte_count = 524288 });
    const oversized: [protocol.image_data_chunk_bytes + 1]u8 = @splat(0);
    const frames = [_]TestFrame{
        .{ .kind = .image_begin, .payload = &begin },
        .{ .kind = .image_data, .payload = &oversized },
    };
    var reader = TestFrames{ .frames = &frames };
    try std.testing.expectError(error.InvalidResource, receiveFrom(&reader, std.testing.allocator, 7, 9));
}

test "image begin and end identities and malformed extent never publish resources" {
    var begin: [protocol.payload_bytes.image_begin]u8 = undefined;
    var end: [protocol.payload_bytes.image_end]u8 = undefined;
    const data = [_]u8{ 1, 2, 3, 4 };
    for (0..6) |case| {
        protocol.encodeImageBegin(&begin, .{ .image_id = if (case == 0) 8 else 7, .generation = if (case == 1) 10 else 9, .width = 1, .height = 1, .byte_count = 4 });
        protocol.encodeImageEnd(&end, .{ .image_id = if (case == 2) 8 else 7, .generation = if (case == 3) 10 else 9 });
        if (case == 4) begin[23] = 8; // byte count disagrees with extent
        if (case == 5) begin[15] = 0; // zero width
        const frames = [_]TestFrame{
            .{ .kind = .image_begin, .payload = &begin },
            .{ .kind = .image_data, .payload = &data },
            .{ .kind = .image_end, .payload = &end },
        };
        var reader = TestFrames{ .frames = &frames };
        try std.testing.expectError(if (case >= 4) error.InvalidPayload else error.InvalidResource, receiveFrom(&reader, std.testing.allocator, 7, 9));
    }
}

fn testResourceAllocation(allocator: std.mem.Allocator) !void {
    var begin: [protocol.payload_bytes.image_begin]u8 = undefined;
    protocol.encodeImageBegin(&begin, .{ .image_id = 7, .generation = 9, .width = 1, .height = 1, .byte_count = 4 });
    var end: [protocol.payload_bytes.image_end]u8 = undefined;
    protocol.encodeImageEnd(&end, .{ .image_id = 7, .generation = 9 });
    const frames = [_]TestFrame{
        .{ .kind = .image_begin, .payload = &begin },
        .{ .kind = .image_data, .payload = &.{ 1, 2, 3 } },
        .{ .kind = .image_data, .payload = &.{4} },
        .{ .kind = .image_end, .payload = &end },
    };
    var reader = TestFrames{ .frames = &frames };
    var resource = try receiveFrom(&reader, allocator, 7, 9);
    defer resource.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, resource.pixels);
}

test "image final allocation failure leaks nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testResourceAllocation, .{});
}

test "truncated real image body frees final pixels and owned begin frame" {
    const posix = std.posix;
    const system = posix.system;
    var pair: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(posix.E.SUCCESS, posix.errno(system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &pair)));
    var count = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const receiver = try client.create(count.allocator(), .{ .fd = pair[0] }, .{ .server_id = 1, .session_id = 1, .instance_id = 1, .tree_revision = 1, .client_id = 1 });
    var receiver_live = true;
    const construction_allocations = count.allocations;
    defer if (receiver_live) receiver.deinit();
    const sender = try client.create(std.testing.allocator, .{ .fd = pair[1] }, .{ .server_id = 1, .session_id = 1, .instance_id = 1, .tree_revision = 1, .client_id = 2 });
    client.stateOf(sender).allocator = std.testing.failing_allocator;
    defer {
        client.stateOf(sender).allocator = std.testing.allocator;
        sender.deinit();
    }
    var begin: [protocol.payload_bytes.image_begin]u8 = undefined;
    protocol.encodeImageBegin(&begin, .{ .image_id = 7, .generation = 9, .width = 2, .height = 2, .byte_count = 16 });
    try sender.send(.image_begin, &begin);
    var partial: [protocol.header_bytes + 3]u8 = @splat(0xa5);
    try protocol.encodeHeader(partial[0..protocol.header_bytes], .{ .kind = .image_data, .payload_len = 16 });
    const sent = system.write(pair[1], &partial, partial.len);
    try std.testing.expectEqual(posix.E.SUCCESS, posix.errno(sent));
    try std.testing.expectEqual(partial.len, sent);
    try std.testing.expectEqual(posix.E.SUCCESS, posix.errno(system.shutdown(pair[1], posix.SHUT.WR)));
    try std.testing.expectError(error.ConnectionClosed, receiveFrom(receiver, count.allocator(), 7, 9));
    try std.testing.expectEqual(construction_allocations + 2, count.allocations);
    receiver.deinit();
    receiver_live = false;
    try std.testing.expect(count.allocations > construction_allocations);
    try std.testing.expectEqual(count.allocations, count.deallocations);
    try std.testing.expectEqual(count.allocated_bytes, count.freed_bytes);
}

const CanceledImageProbe = struct {
    connection: *client.Connection,
    allocator: std.mem.Allocator,
    failure: ?Error = null,
};

fn testCanceledImageReceive(probe: *CanceledImageProbe) void {
    var resource = receiveFrom(probe.connection, probe.allocator, 7, 9) catch |failure| {
        probe.failure = failure;
        return;
    };
    resource.deinit();
}

test "canceling real image receive releases owned frames and pixels" {
    const posix = std.posix;
    var pair: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(posix.E.SUCCESS, posix.errno(posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &pair)));
    var count = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const receiver = try client.create(count.allocator(), .{ .fd = pair[0] }, .{ .server_id = 1, .session_id = 1, .instance_id = 1, .tree_revision = 1, .client_id = 1 });
    var receiver_live = true;
    const construction_allocations = count.allocations;
    defer if (receiver_live) receiver.deinit();
    const sender = try client.create(std.testing.allocator, .{ .fd = pair[1] }, .{ .server_id = 1, .session_id = 1, .instance_id = 1, .tree_revision = 1, .client_id = 2 });
    client.stateOf(sender).allocator = std.testing.failing_allocator;
    defer {
        client.stateOf(sender).allocator = std.testing.allocator;
        sender.deinit();
    }
    var begin: [protocol.payload_bytes.image_begin]u8 = undefined;
    protocol.encodeImageBegin(&begin, .{ .image_id = 7, .generation = 9, .width = 2, .height = 2, .byte_count = 16 });
    try sender.send(.image_begin, &begin);
    try sender.send(.image_data, &.{ 1, 2, 3, 4 });
    var cancellation = try receiver.cancellation();
    defer cancellation.deinit();
    var probe = CanceledImageProbe{ .connection = receiver, .allocator = count.allocator() };
    const worker = try std.Thread.spawn(.{}, testCanceledImageReceive, .{&probe});
    {
        defer {
            // zig-audit: acknowledge panic
            // reason: This fixture must wake its blocked receiver before join; a failed cancellation aborts the proof instead of risking an indefinite join.
            cancellation.cancel() catch @panic("image receive fixture cancellation failed");
            worker.join();
        }
        try std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake);
        try cancellation.cancel();
    }
    try std.testing.expectEqual(error.ConnectionClosed, probe.failure.?);
    receiver.deinit();
    receiver_live = false;
    try std.testing.expect(count.allocations > construction_allocations);
    try std.testing.expectEqual(count.allocations, count.deallocations);
    try std.testing.expectEqual(count.allocated_bytes, count.freed_bytes);
}
