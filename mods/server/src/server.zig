//! Optional orchestration owner: Server -> Sessions -> Instances.
//!
//! Server owns Session identity/lifetime only. Session creation never creates an
//! Instance; concrete terminal launch belongs to explicit Instance creation.

const std = @import("std");
const server_protocol = @import("server_protocol");
const session_mod = @import("session.zig");
const howl_instance = @import("howl_instance");

/// Nonzero identity of a Session within one Server incarnation.
pub const SessionId = u64;
/// Bound on simultaneously owned Sessions.
pub const maximum_sessions: usize = 16;
/// Bound on simultaneously owned Instances in each Session.
pub const maximum_instances_per_session: usize = session_mod.maximum_instances;
/// Copied Instance identity and lifecycle facts.
pub const InstanceView = session_mod.InstanceView;

/// Session identity/count facts with a name borrowed until the next mutation.
pub const SessionView = struct {
    id: SessionId,
    name: []const u8,
    instance_count: u16,
};

/// Reports allocation, invalid name, duplicate name, capacity or identity exhaustion.
pub const CreateSessionError = std.mem.Allocator.Error || error{
    InvalidName,
    NameExists,
    Capacity,
    IdentityExhausted,
};

// Only this file can recover the owning records; public handles carry no typed
// path to mutable nested Session/Instance storage.
const Storage = struct {
    allocator: std.mem.Allocator,
    id: u64,
    next_session_id: SessionId = 1,
    revision: u64 = 1,
    sessions: [maximum_sessions]?*session_mod.Session = @splat(null),
    count: u16 = 0,
};
/// Opaque owner of the bounded Session catalogue and its nested Instance lifetimes.
// zig-audit: acknowledge opaque_type
// reason: Server hides its allocator-owned Session/Instance records so callers cannot bypass orchestration lifetime and capacity checks.
pub const Server = opaque {
    fn stateMut(self: *Server) *Storage {
        // zig-audit: acknowledge ptr_cast
        // reason: Server.init creates a Storage allocation and publishes the same address; only this owner recovers or adapts its handle.
        // zig-audit: acknowledge align_cast
        // reason: Every Server handle originates from allocator.create(Storage), preserving Storage alignment until deinit.
        return @ptrCast(@alignCast(self));
    }

    fn stateConst(self: *const Server) *const Storage {
        // zig-audit: acknowledge ptr_cast
        // reason: Server.init creates a Storage allocation and publishes the same address; only this owner recovers or adapts its handle.
        // zig-audit: acknowledge align_cast
        // reason: Every Server handle originates from allocator.create(Storage), preserving Storage alignment until deinit.
        return @ptrCast(@alignCast(self));
    }

    /// Allocates an empty Server for a caller-owned nonzero incarnation identity.
    pub fn init(allocator: std.mem.Allocator, id: u64) (std.mem.Allocator.Error || error{InvalidServerIdentity})!*Server {
        if (id == 0) return error.InvalidServerIdentity;
        const storage = try allocator.create(Storage);
        storage.* = .{ .allocator = allocator, .id = id };
        // zig-audit: acknowledge ptr_cast
        // reason: Server.init creates a Storage allocation and publishes the same address; only this owner recovers or adapts its handle.
        return @ptrCast(storage);
    }

    /// Returns the immutable Server incarnation identity.
    pub fn identity(self: *const Server) u64 {
        return self.stateConst().id;
    }

    /// Releases every nested Session and then this Server allocation.
    pub fn deinit(self: *Server) void {
        var index = self.stateMut().sessions.len;
        while (index != 0) {
            index -= 1;
            if (self.stateMut().sessions[index]) |record| {
                record.deinit();
                self.stateMut().sessions[index] = null;
            }
        }
        self.stateMut().allocator.destroy(self.stateMut());
    }

    /// Returns the number of retained Sessions.
    pub fn sessionCount(self: *const Server) u16 {
        return self.stateConst().count;
    }

    /// Returns the current nonzero catalogue observation revision.
    pub fn treeRevision(self: *const Server) u64 {
        return self.stateConst().revision;
    }

    /// Returns the total number of retained Instances across all Sessions.
    pub fn instanceCountTotal(self: *const Server) u16 {
        var total: u16 = 0;
        for (self.stateConst().sessions) |maybe_record| {
            const record = maybe_record orelse continue;
            total += record.instanceCount();
        }
        return total;
    }

    /// Counts Instances with service work requiring a scheduler turn.
    pub fn turnInstanceCount(self: *const Server) u16 {
        var total: u16 = 0;
        for (self.stateConst().sessions) |maybe_record| {
            const record = maybe_record orelse continue;
            total += record.turnInstanceCount();
        }
        return total;
    }

    /// Returns pending-work status, or null for an unknown occurrence.
    pub fn instanceRequiresTurn(
        self: *const Server,
        session_id: SessionId,
        instance_id: session_mod.InstanceId,
    ) ?bool {
        const index = self.findSessionIndex(session_id) orelse return null;
        return self.stateConst().sessions[index].?.instanceRequiresTurn(instance_id);
    }

    /// Borrows a live Instance wait descriptor, or null when unavailable.
    pub fn instanceWaitDescriptor(
        self: *const Server,
        session_id: SessionId,
        instance_id: session_mod.InstanceId,
    ) error{NotStarted}!?std.posix.fd_t {
        const index = self.findSessionIndex(session_id) orelse return null;
        return try self.stateConst().sessions[index].?.instanceWaitDescriptor(instance_id);
    }

    /// Borrows Session names until the next Server mutation; scalar fields are copied.
    pub fn snapshotSessions(self: *const Server, output: *[maximum_sessions]SessionView) []const SessionView {
        var count: usize = 0;
        for (self.stateConst().sessions) |maybe_record| {
            const record = maybe_record orelse continue;
            var insert = count;
            while (insert != 0 and output[insert - 1].id > record.id) : (insert -= 1)
                output[insert] = output[insert - 1];
            output[insert] = .{
                .id = record.id,
                .name = record.name,
                .instance_count = record.instanceCount(),
            };
            count += 1;
        }
        std.debug.assert(count == self.stateConst().count);
        return output[0..count];
    }

    /// Copies one Session's ordered Instance facts into caller-owned storage.
    pub fn snapshotInstances(
        self: *const Server,
        session_id: SessionId,
        output: *[session_mod.maximum_instances]session_mod.InstanceView,
    ) ?[]const session_mod.InstanceView {
        const index = self.findSessionIndex(session_id) orelse return null;
        return self.stateConst().sessions[index].?.snapshotInstances(output);
    }

    /// Validates and copies a unique name into a newly owned Session.
    pub fn createSession(self: *Server, name: []const u8) CreateSessionError!SessionId {
        server_protocol.validateSessionName(name) catch return error.InvalidName;
        if (self.findSessionByName(name) != null) return error.NameExists;
        if (self.stateMut().count == self.stateMut().sessions.len) return error.Capacity;
        if (self.stateMut().next_session_id == 0) return error.IdentityExhausted;
        // zig-audit: acknowledge orelse_unreachable
        // reason: The maintained count is checked below the fixed Session slot capacity before this synchronous free-slot lookup.
        const slot = self.freeSlot() orelse unreachable;
        const id = self.stateMut().next_session_id;
        const value = session_mod.Session.init(self.stateMut().allocator, id, name) catch |failure| switch (failure) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidName => return error.InvalidName,
        };
        errdefer value.deinit();
        self.stateMut().next_session_id = advanceIdentity(id) catch return error.IdentityExhausted;
        self.stateMut().sessions[slot] = value;
        self.stateMut().count += 1;
        self.bumpRevision();
        return id;
    }

    /// Destroys an existing Session and its Instances; returns whether it existed.
    pub fn closeSession(self: *Server, id: SessionId) bool {
        const index = self.findSessionIndex(id) orelse return false;
        if (self.stateMut().sessions[index]) |record| record.deinit();
        self.stateMut().sessions[index] = null;
        self.stateMut().count -= 1;
        self.bumpRevision();
        return true;
    }

    /// Reports Instance construction failure or a missing Session.
    pub const CreateInstanceError = session_mod.CreateInstanceError || error{SessionNotFound};

    /// Creates one explicitly launched Instance inside the selected Session.
    pub fn createInstance(
        self: *Server,
        session_id: SessionId,
        io: std.Io,
        inherited_environment: std.process.Environ,
        launch: howl_instance.Launch,
    ) CreateInstanceError!session_mod.InstanceId {
        const index = self.findSessionIndex(session_id) orelse return error.SessionNotFound;
        const instance_id = try self.stateMut().sessions[index].?.createInstance(io, inherited_environment, launch);
        self.bumpRevision();
        return instance_id;
    }

    /// Closes one selected Instance and reports whether it existed.
    pub fn closeInstance(self: *Server, session_id: SessionId, instance_id: session_mod.InstanceId) bool {
        const index = self.findSessionIndex(session_id) orelse return false;
        const closed = self.stateMut().sessions[index].?.closeInstance(instance_id);
        if (closed) self.bumpRevision();
        return closed;
    }

    /// Returns the retained Instance count, or null for an unknown Session.
    pub fn instanceCount(self: *const Server, session_id: SessionId) ?u16 {
        const index = self.findSessionIndex(session_id) orelse return null;
        return self.stateConst().sessions[index].?.instanceCount();
    }

    /// Returns copied lifecycle state, or null for an unknown occurrence.
    pub fn instanceState(self: *const Server, session_id: SessionId, instance_id: session_mod.InstanceId) ?session_mod.InstanceState {
        const index = self.findSessionIndex(session_id) orelse return null;
        return self.stateConst().sessions[index].?.instanceState(instance_id);
    }

    /// Reports stream adoption failure or a missing Session.
    pub const AdoptClientError = session_mod.Session.AdoptClientError || error{SessionNotFound};

    /// Transfers a connected stream to the selected Instance only on success.
    pub fn adoptClient(
        self: *Server,
        session_id: SessionId,
        instance_id: session_mod.InstanceId,
        fd: std.posix.fd_t,
        initial_input: []const u8,
    ) AdoptClientError!void {
        const index = self.findSessionIndex(session_id) orelse return error.SessionNotFound;
        return self.stateMut().sessions[index].?.adoptClient(instance_id, fd, initial_input, .{
            .server_id = self.identity(),
            .session_id = session_id,
            .instance_id = instance_id,
            .tree_revision = self.treeRevision(),
        });
    }

    /// Reports Instance service failure or a missing Session.
    pub const TurnInstanceError = session_mod.Session.TurnInstanceError || error{SessionNotFound};

    /// Services one selected Instance and advances catalogue revision on lifecycle change.
    pub fn turnInstance(
        self: *Server,
        session_id: SessionId,
        instance_id: session_mod.InstanceId,
        timeout_ms: i32,
    ) TurnInstanceError!void {
        const index = self.findSessionIndex(session_id) orelse return error.SessionNotFound;
        const outcome = try self.stateMut().sessions[index].?.turnInstance(instance_id, timeout_ms);
        if (outcome.state_changed) self.bumpRevision();
    }

    /// Looks up an existing Session by its exact name.
    pub fn findSessionByName(self: *const Server, name: []const u8) ?SessionId {
        for (self.stateConst().sessions) |maybe_record| {
            const record = maybe_record orelse continue;
            if (std.mem.eql(u8, record.name, name)) return record.id;
        }
        return null;
    }

    fn bumpRevision(self: *Server) void {
        self.stateMut().revision +%= 1;
        if (self.stateMut().revision == 0) self.stateMut().revision = 1;
    }

    fn freeSlot(self: *const Server) ?usize {
        for (self.stateConst().sessions, 0..) |record, index| if (record == null) return index;
        return null;
    }

    fn findSessionIndex(self: *const Server, id: SessionId) ?usize {
        for (self.stateConst().sessions, 0..) |maybe_record, index| {
            const record = maybe_record orelse continue;
            if (record.id == id) return index;
        }
        return null;
    }
};

test "Server identity is explicit and nonzero" {
    try std.testing.expectError(error.InvalidServerIdentity, Server.init(std.testing.allocator, 0));
    const server = try Server.init(std.testing.allocator, 99);
    defer server.deinit();
    try std.testing.expectEqual(@as(u64, 99), server.identity());
}

test "Server observations are sorted after slot reuse" {
    const server = try Server.init(std.testing.allocator, 42);
    defer server.deinit();
    const first = try server.createSession("first");
    const second = try server.createSession("second");
    try std.testing.expect(server.closeSession(first));
    const third = try server.createSession("third");
    try std.testing.expect(third > second);

    var sessions_storage: [maximum_sessions]SessionView = undefined;
    const sessions = server.snapshotSessions(&sessions_storage);
    try std.testing.expectEqual(@as(usize, 2), sessions.len);
    try std.testing.expectEqual(second, sessions[0].id);
    try std.testing.expectEqual(third, sessions[1].id);
    try std.testing.expectEqualStrings("second", sessions[0].name);
    try std.testing.expectEqualStrings("third", sessions[1].name);
}

test "Server routes Instance creation through the selected Session" {
    const server = try Server.init(std.testing.allocator, 41);
    defer server.deinit();
    const work = try server.createSession("work");
    const other = try server.createSession("other");
    const instance_id = try server.createInstance(work, std.testing.io, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "exit 0",
        .rows = 4,
        .columns = 12,
    });
    try std.testing.expectEqual(@as(session_mod.InstanceId, 1), instance_id);
    try std.testing.expectEqual(@as(u16, 1), server.instanceCount(work).?);
    try std.testing.expectEqual(@as(u16, 0), server.instanceCount(other).?);
    try std.testing.expect(server.closeInstance(work, instance_id));
    try std.testing.expectEqual(@as(u16, 0), server.instanceCount(work).?);
    try std.testing.expectEqual(work, server.findSessionByName("work").?);
}

fn advanceIdentity(current: u64) error{IdentityExhausted}!u64 {
    if (current == std.math.maxInt(u64)) return error.IdentityExhausted;
    const next = current + 1;
    if (next == 0) return error.IdentityExhausted;
    return next;
}

test "Server creates empty Sessions without constructing Instances" {
    const server = try Server.init(std.testing.allocator, 41);
    defer server.deinit();

    const work = try server.createSession("work");
    try std.testing.expectEqual(@as(SessionId, 1), work);
    try std.testing.expectEqual(@as(u16, 1), server.sessionCount());
    try std.testing.expectEqual(@as(u16, 0), server.instanceCount(work).?);
}

test "Session identity survives Instance-independent CRUD" {
    const server = try Server.init(std.testing.allocator, 41);
    defer server.deinit();
    const first = try server.createSession("first");
    const second = try server.createSession("second");
    try std.testing.expect(first != second);
    try std.testing.expect(server.closeSession(first));
    try std.testing.expectEqual(second, server.findSessionByName("second").?);
    try std.testing.expectEqual(@as(u16, 1), server.sessionCount());
}

fn testSetNonblocking(fd: std.posix.fd_t) !void {
    const linux = std.os.linux;
    const current = linux.fcntl(fd, linux.F.GETFL, @as(usize, 0));
    if (linux.errno(current) != .SUCCESS) return error.TestSocketConfigureFailed;
    const nonblocking: usize = @intCast(@as(u32, @bitCast(linux.O{ .NONBLOCK = true })));
    const updated = linux.fcntl(fd, linux.F.SETFL, @as(usize, @intCast(current)) | nonblocking);
    if (linux.errno(updated) != .SUCCESS) return error.TestSocketConfigureFailed;
}

fn testCloseFd(fd: std.posix.fd_t) void {
    const linux = std.os.linux;
    const result = linux.close(fd);
    const errno = linux.errno(result);
    std.debug.assert(errno == .SUCCESS or errno == .INTR);
}

fn testReadExact(
    server: *Server,
    session_id: SessionId,
    instance_id: session_mod.InstanceId,
    fd: std.posix.fd_t,
    output: []u8,
) !void {
    const linux = std.os.linux;
    var offset: usize = 0;
    var turns: usize = 0;
    while (offset < output.len and turns < 10_000) : (turns += 1) {
        const result = linux.read(fd, output[offset..].ptr, output.len - offset);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0 or result > output.len - offset) return error.TestSocketReadFailed;
                offset += result;
            },
            .INTR => continue,
            .AGAIN => try server.turnInstance(session_id, instance_id, 1),
            else => return error.TestSocketReadFailed,
        }
    }
    if (offset != output.len) return error.TestTimeout;
}

test "Server routes an adopted Server terminal stream by exact Session and Instance identity" {
    const protocol = @import("server_protocol").terminal;
    const server = try Server.init(std.testing.allocator, 41);
    defer server.deinit();
    const work = try server.createSession("work");
    const instance_id = try server.createInstance(work, std.testing.io, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "cat",
        .rows = 4,
        .columns = 20,
    });

    var pair: [2]std.posix.fd_t = undefined;
    const socket_result = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair);
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(socket_result));
    var service_owns = false;
    defer if (!service_owns) testCloseFd(pair[0]);
    defer testCloseFd(pair[1]);
    try testSetNonblocking(pair[1]);

    try server.adoptClient(work, instance_id, pair[0], &.{});
    service_owns = true;

    const control = @import("server_protocol");
    var header_bytes: [control.header_bytes]u8 = undefined;
    try testReadExact(server, work, instance_id, pair[1], &header_bytes);
    const header = try control.decodeHeader(&header_bytes);
    try std.testing.expectEqual(control.Kind.attach_ready, header.kind);
    try std.testing.expectEqual(@as(u32, control.payload_bytes.attach_ready), header.payload_len);
    var ready_bytes: [control.payload_bytes.attach_ready]u8 = undefined;
    try testReadExact(server, work, instance_id, pair[1], &ready_bytes);
    const ready = try control.decodeAttachReady(&ready_bytes);
    try std.testing.expectEqual(server.identity(), ready.server_id);
    try std.testing.expectEqual(work, ready.session_id);
    try std.testing.expectEqual(instance_id, ready.instance_id);
    try std.testing.expect(ready.client_id != protocol.no_client);
}

test "identity routing failure retains caller stream ownership" {
    const linux = std.os.linux;
    const server = try Server.init(std.testing.allocator, 41);
    defer server.deinit();
    const work = try server.createSession("work");
    const instance_id = try server.createInstance(work, std.testing.io, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "cat",
        .rows = 2,
        .columns = 8,
    });

    var pair: [2]std.posix.fd_t = undefined;
    const socket_result = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &pair);
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(socket_result));
    defer testCloseFd(pair[0]);
    defer testCloseFd(pair[1]);

    try std.testing.expectError(
        error.SessionNotFound,
        server.adoptClient(work + 100, instance_id, pair[0], &.{}),
    );
    const session_flags = linux.fcntl(pair[0], linux.F.GETFD, @as(usize, 0));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(session_flags));

    try std.testing.expectError(
        error.InstanceNotFound,
        server.adoptClient(work, instance_id + 100, pair[0], &.{}),
    );
    const instance_flags = linux.fcntl(pair[0], linux.F.GETFD, @as(usize, 0));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(instance_flags));
}

test "Instance exit advances tree revision without ending its Session" {
    const server = try Server.init(std.testing.allocator, 41);
    defer server.deinit();
    try std.testing.expectEqual(@as(u64, 1), server.treeRevision());

    const work = try server.createSession("work");
    try std.testing.expectEqual(@as(u64, 2), server.treeRevision());
    const instance_id = try server.createInstance(work, std.testing.io, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "exit 0",
        .rows = 2,
        .columns = 8,
    });
    try std.testing.expectEqual(@as(u64, 3), server.treeRevision());
    try std.testing.expectEqual(session_mod.InstanceState.running, server.instanceState(work, instance_id).?);

    var turns: usize = 0;
    while (turns < 10_000 and server.instanceState(work, instance_id).? == .running) : (turns += 1)
        try server.turnInstance(work, instance_id, 1);
    try std.testing.expectEqual(session_mod.InstanceState.exited, server.instanceState(work, instance_id).?);
    try std.testing.expectEqual(@as(u64, 4), server.treeRevision());
    try std.testing.expectEqual(work, server.findSessionByName("work").?);
    try std.testing.expectEqual(@as(u16, 1), server.sessionCount());
    try std.testing.expectEqual(@as(u16, 1), server.instanceCount(work).?);

    var settle: usize = 0;
    while (settle < 10_000 and server.instanceRequiresTurn(work, instance_id) == true) : (settle += 1)
        try server.turnInstance(work, instance_id, 1);
    try std.testing.expect(server.instanceRequiresTurn(work, instance_id) == false);
    try std.testing.expectEqual(@as(u16, 0), server.turnInstanceCount());
    try std.testing.expectEqual(@as(u64, 4), server.treeRevision());
    try std.testing.expectEqual(work, server.findSessionByName("work").?);
}

test "Session names accepted by the model are closed under wire publication" {
    const server = try Server.init(std.testing.allocator, 42);
    defer server.deinit();
    const maximum_name: [server_protocol.maximum_session_name_bytes]u8 = @splat('a');
    for ([_][]const u8{ "a", "AZaz09._-", &maximum_name }) |name| {
        const sid = try server.createSession(name);
        var views: [maximum_sessions]SessionView = undefined;
        const view = server.snapshotSessions(&views)[0];
        var output: [server_protocol.maximum_payload_bytes]u8 = undefined;
        const wire = try server_protocol.encodeTreeSnapshot(&output, .{
            .server_id = server.identity(),
            .tree_revision = server.treeRevision(),
            .session_count = 1,
            .instance_count = 0,
        }, &.{.{ .session_id = sid, .name = view.name, .instances = &.{} }});
        var iterator = try server_protocol.TreeDecoder.init(wire);
        const decoded = (try iterator.nextSession()).?;
        try std.testing.expectEqualStrings(name, decoded.name);
        try std.testing.expect(server.closeSession(sid));
    }
}

test "invalid Session names reject transactionally with one model and wire contract" {
    const server = try Server.init(std.testing.allocator, 42);
    defer server.deinit();
    const oversized: [server_protocol.maximum_session_name_bytes + 1]u8 = @splat('a');
    for ([_][]const u8{ "", "has space", "slash/name", "nul\x00", "line\n", "é", &oversized }) |name| {
        try std.testing.expectError(error.InvalidName, server.createSession(name));
        try std.testing.expectError(error.InvalidPayload, server_protocol.validateSessionName(name));
        try std.testing.expectEqual(@as(u16, 0), server.sessionCount());
        try std.testing.expectEqual(@as(u64, 1), server.treeRevision());
    }
    try std.testing.expectEqual(@as(u64, 1), try server.createSession("valid"));
}

test "Server storage recovery preserves owner constness" {
    try std.testing.expectEqual(*Storage, @typeInfo(@TypeOf(Server.stateMut)).@"fn".return_type.?);
    try std.testing.expectEqual(*const Storage, @typeInfo(@TypeOf(Server.stateConst)).@"fn".return_type.?);
}

test "Session storage and name allocation failures do not publish model state" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const server = try Server.init(failing.allocator(), 42);
    defer server.deinit();
    for (0..2) |offset| {
        failing.fail_index = failing.alloc_index + offset;
        try std.testing.expectError(error.OutOfMemory, server.createSession("work"));
        try std.testing.expectEqual(@as(u16, 0), server.sessionCount());
        try std.testing.expectEqual(@as(u64, 1), server.treeRevision());
    }
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(@as(u64, 1), try server.createSession("work"));
}
