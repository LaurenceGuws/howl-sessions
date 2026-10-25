//! Bounded client-side host-consequence authority and snapshot operations.
//!
//! The frozen Instance wire carries consequence snapshots as begin/data/end
//! frames. This module owns that framing and exposes one immutable caller-owned
//! payload plus typed protocol metadata. Host policy remains outside the client.

const std = @import("std");
const protocol = @import("server_protocol").terminal;
const client = @import("terminal_owner");

/// Canonical consequence kind carried by one retained occurrence.
pub const Kind = protocol.ConsequenceKind;
/// Canonical typed reply kind for a consequence requiring host input.
pub const ReplyKind = protocol.ConsequenceReplyKind;
/// Metadata beginning one coherent consequence snapshot.
pub const Begin = protocol.ConsequenceBegin;

/// Reports transport, framing, authority, and snapshot failures.
pub const Error = client.Error || std.mem.Allocator.Error || protocol.PayloadError || error{
    UnexpectedFrame,
    InvalidSnapshot,
    ServerRejected,
    NotAuthority,
};

/// Owns one coherent consequence snapshot payload and its generation metadata.
pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    begin: Begin,
    payload: []u8,

    /// Releases the owned snapshot payload.
    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.payload);
        self.* = undefined;
    }
};

/// Assigns consequence authority to one exact attached client id.
pub fn assign(connection: *client.Connection, client_id: protocol.ClientId) Error!void {
    var payload: [protocol.payload_bytes.assign_consequence_leader]u8 = undefined;
    protocol.encodeAssignLeader(&payload, .{ .client_id = client_id });
    try connection.send(.assign_consequence_leader, &payload);
    try expectOk(connection, .assign_consequence_leader);
}

/// Claims consequence authority for this exact connection.
pub fn acquire(connection: *client.Connection) Error!void {
    return assign(connection, connection.identity().client_id);
}

/// Explicitly clears consequence authority through the frozen no-client id.
pub fn release(connection: *client.Connection) Error!void {
    return assign(connection, protocol.no_client);
}

/// Requests and owns one coherent current consequence snapshot.
pub fn observe(connection: *client.Connection, allocator: std.mem.Allocator) Error!Snapshot {
    try connection.send(.consequence_observe, &.{});
    var completed = false;
    defer if (!completed) client.retire(connection);
    const snapshot = receiveFrom(connection, allocator) catch |failure| {
        if (failure == error.NotAuthority or failure == error.ServerRejected) completed = true;
        return failure;
    };
    completed = true;
    return snapshot;
}

// zig-audit: acknowledge anytype
// reason: The receiver is shared by the real Connection and a narrow test framing fixture with the same receive contract.
fn receiveFrom(connection: anytype, allocator: std.mem.Allocator) Error!Snapshot {
    var begin_frame = try connection.receive();
    defer begin_frame.deinit();
    if (begin_frame.kind == .result) {
        const result = try protocol.decodeResult(begin_frame.payload);
        if (result.request_kind != .consequence_observe or result.code == .ok)
            return error.UnexpectedFrame;
        if (result.code == .not_leader) return error.NotAuthority;
        return error.ServerRejected;
    }
    if (begin_frame.kind != .consequence_begin) return error.UnexpectedFrame;
    const begin = try protocol.decodeConsequenceBegin(begin_frame.payload);
    const payload = try allocator.alloc(u8, begin.payload_len);
    errdefer allocator.free(payload);
    var offset: usize = 0;
    while (offset < payload.len) {
        var frame = try connection.receive();
        defer frame.deinit();
        if (frame.kind != .consequence_data or frame.payload.len == 0 or
            frame.payload.len > protocol.consequence_data_chunk_bytes or
            frame.payload.len > payload.len - offset)
            return error.InvalidSnapshot;
        @memcpy(payload[offset..][0..frame.payload.len], frame.payload);
        offset += frame.payload.len;
    }
    var end_frame = try connection.receive();
    defer end_frame.deinit();
    if (end_frame.kind != .consequence_end) return error.UnexpectedFrame;
    const generation = try protocol.decodeConsequenceEnd(end_frame.payload);
    if (generation != begin.generation) return error.InvalidSnapshot;
    return .{ .allocator = allocator, .begin = begin, .payload = payload };
}

/// Consumes one exact non-reply consequence while this connection owns authority.
pub fn consume(connection: *client.Connection, generation: u64) Error!void {
    var payload: [protocol.payload_bytes.consequence_consume]u8 = undefined;
    protocol.encodeConsequenceIdentity(&payload, generation);
    try connection.send(.consequence_consume, &payload);
    try expectOk(connection, .consequence_consume);
}

/// Sends one typed reply to the exact pending consequence generation.
pub fn reply(
    connection: *client.Connection,
    generation: u64,
    kind: ReplyKind,
    body: []const u8,
) Error!void {
    const payload = try client.ownerAllocator(connection).alloc(u8, protocol.payload_bytes.consequence_reply_header + body.len);
    defer client.ownerAllocator(connection).free(payload);
    const encoded = try protocol.encodeConsequenceReply(payload, generation, kind, body);
    try connection.send(.consequence_reply, encoded);
    try expectOk(connection, .consequence_reply);
}

fn expectOk(connection: *client.Connection, expected: protocol.Kind) Error!void {
    var completed = false;
    defer if (!completed) client.retire(connection);
    var frame = try connection.receive();
    defer frame.deinit();
    if (frame.kind != .result) return error.UnexpectedFrame;
    const result = try protocol.decodeResult(frame.payload);
    if (result.request_kind != expected) return error.UnexpectedFrame;
    completed = true;
    return switch (result.code) {
        .ok => {},
        .not_leader => error.NotAuthority,
        else => error.ServerRejected,
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

    fn receive(self: *TestFrames) Error!TestFrame {
        if (self.index >= self.frames.len) return error.UnexpectedFrame;
        defer self.index += 1;
        return self.frames[self.index];
    }
};

test "consequence snapshot receiver owns exact chunked payload" {
    var begin_bytes: [protocol.payload_bytes.consequence_begin]u8 = undefined;
    var metadata: [protocol.consequence_metadata_bytes]u8 = @splat(0);
    metadata[0] = @backingInt(protocol.ConsequenceNotificationKind.message);
    try protocol.encodeConsequenceBegin(&begin_bytes, .{
        .terminal_revision = 8,
        .authority_client_id = 4,
        .generation = 12,
        .payload_len = 5,
        .kind = .notification,
        .reply_required = false,
        .metadata = metadata,
    });
    var end_bytes: [protocol.payload_bytes.consequence_end]u8 = undefined;
    protocol.encodeConsequenceEnd(&end_bytes, 12);
    const one = [_]u8{ 'h', 'e' };
    const two = [_]u8{ 'l', 'l', 'o' };
    const frames = [_]TestFrame{
        .{ .kind = .consequence_begin, .payload = &begin_bytes },
        .{ .kind = .consequence_data, .payload = &one },
        .{ .kind = .consequence_data, .payload = &two },
        .{ .kind = .consequence_end, .payload = &end_bytes },
    };
    var reader = TestFrames{ .frames = &frames };
    var snapshot = try receiveFrom(&reader, std.testing.allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(Kind.notification, snapshot.begin.kind);
    try std.testing.expectEqual(@as(u64, 12), snapshot.begin.generation);
    try std.testing.expectEqualStrings("hello", snapshot.payload);
}

test "consequence snapshot receiver rejects mismatched end identity" {
    var begin_bytes: [protocol.payload_bytes.consequence_begin]u8 = undefined;
    try protocol.encodeConsequenceBegin(&begin_bytes, .{
        .terminal_revision = 8,
        .authority_client_id = 4,
        .generation = 12,
        .payload_len = 0,
        .kind = .bell,
        .reply_required = false,
        .metadata = @splat(0),
    });
    var end_bytes: [protocol.payload_bytes.consequence_end]u8 = undefined;
    protocol.encodeConsequenceEnd(&end_bytes, 13);
    const frames = [_]TestFrame{
        .{ .kind = .consequence_begin, .payload = &begin_bytes },
        .{ .kind = .consequence_end, .payload = &end_bytes },
    };
    var reader = TestFrames{ .frames = &frames };
    try std.testing.expectError(
        error.InvalidSnapshot,
        receiveFrom(&reader, std.testing.allocator),
    );
}
