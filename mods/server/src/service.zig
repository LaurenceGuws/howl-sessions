//! Listener-free control service for one borrowed Server.
//!
//! The service owns only bounded adopted control streams, framing buffers and
//! long-poll state. It never creates a listener, address, process, Session or
//! Instance lifetime. Exact attach transfers the existing stream into the
//! selected Instance interaction service without a byte proxy.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const model = @import("server_model");
const protocol = @import("server_protocol");
const instance_protocol = @import("server_protocol").terminal;

const maximum_clients: usize = 16;
const input_bytes: usize = protocol.header_bytes + protocol.maximum_request_payload_bytes;
const output_bytes: usize = protocol.header_bytes + protocol.maximum_payload_bytes;

const Client = struct {
    fd: posix.fd_t,
    input: []u8,
    input_len: usize = 0,
    output: []u8,
    output_len: usize = 0,
    output_offset: usize = 0,
    welcomed: bool = false,
    observe_after: ?u64 = null,

    fn init(allocator: std.mem.Allocator, fd: posix.fd_t, initial_input: []const u8) !Client {
        if (initial_input.len > input_bytes) return error.InitialInputTooLarge;
        const input = try allocator.alloc(u8, input_bytes);
        errdefer allocator.free(input);
        @memcpy(input[0..initial_input.len], initial_input);
        const output = try allocator.alloc(u8, output_bytes);
        return .{
            .fd = fd,
            .input = input,
            .input_len = initial_input.len,
            .output = output,
        };
    }

    fn deinit(self: *Client, allocator: std.mem.Allocator) void {
        closeFd(self.fd);
        self.releaseBuffers(allocator);
    }

    fn releaseTransferred(self: *Client, allocator: std.mem.Allocator) void {
        self.releaseBuffers(allocator);
    }

    fn releaseBuffers(self: *Client, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        allocator.free(self.input);
        self.* = undefined;
    }

    fn outputPending(self: *const Client) bool {
        return self.output_offset < self.output_len;
    }

    fn resetOutput(self: *Client) void {
        self.output_len = 0;
        self.output_offset = 0;
    }
};

/// Owns bounded adopted control clients while borrowing the Server model.
pub const Service = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    inherited_environment: std.process.Environ,
    server: *model.Server,
    clients: [maximum_clients]?Client = @splat(null),

    /// Borrows `server` and `inherited_environment`; both must outlive Service.
    /// `io` supplies control-stream polling and explicit Instance construction only.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        inherited_environment: std.process.Environ,
        server: *model.Server,
    ) Service {
        return .{
            .allocator = allocator,
            .io = io,
            .inherited_environment = inherited_environment,
            .server = server,
        };
    }

    /// Closes all adopted clients and releases their buffers.
    pub fn deinit(self: *Service) void {
        for (&self.clients) |*maybe_client| {
            if (maybe_client.*) |*client| client.deinit(self.allocator);
            maybe_client.* = null;
        }
        self.* = undefined;
    }

    /// Returns the number of retained control clients.
    pub fn clientCount(self: *const Service) u16 {
        var count: u16 = 0;
        for (self.clients) |client| {
            if (client != null) count += 1;
        }
        return count;
    }

    /// Maximum number of control readiness records returned by this service.
    pub const maximum_wait_descriptors: usize = maximum_clients;

    /// Borrowed control descriptor and requested poll events.
    pub const WaitDescriptor = struct {
        fd: posix.fd_t,
        events: i16,
    };

    /// Snapshots exact socket readiness interests for caller-owned aggregate polling.
    /// Tree-revision wakeups remain service-owned and require an explicit zero-timeout
    /// `turn` after the borrowed Server model changes.
    pub fn snapshotWaitDescriptors(
        self: *const Service,
        output: *[maximum_wait_descriptors]WaitDescriptor,
    ) []const WaitDescriptor {
        var count: usize = 0;
        for (self.clients) |maybe_client| {
            const client = maybe_client orelse continue;
            output[count] = .{
                .fd = client.fd,
                .events = clientPollEvents(client),
            };
            count += 1;
        }
        return output[0..count];
    }

    /// Reports adoption allocation, client-capacity, input-size or descriptor configuration failure.
    pub const AdoptError = std.mem.Allocator.Error || error{
        ClientCapacity,
        InitialInputTooLarge,
        SocketOptionFailed,
    };

    /// Adopts one already-connected control stream. On failure the caller keeps fd.
    pub fn adoptClient(self: *Service, fd: posix.fd_t, initial_input: []const u8) AdoptError!void {
        const slot = self.freeClientSlot() orelse return error.ClientCapacity;
        var client = try Client.init(self.allocator, fd, initial_input);
        errdefer client.releaseBuffers(self.allocator);
        try configureAdoptedFd(fd);
        self.clients[slot] = client;
    }

    /// Services only control streams. Instance service turns remain runtime-owned.
    pub fn turn(self: *Service, timeout_ms: i32) !void {
        self.processBufferedRequests();
        self.materializeTreeObservers();

        var descriptors: [maximum_clients]posix.pollfd = undefined;
        for (self.clients, 0..) |maybe_client, index| {
            if (maybe_client) |client| {
                descriptors[index] = .{
                    .fd = client.fd,
                    .events = clientPollEvents(client),
                    .revents = 0,
                };
            } else {
                descriptors[index] = .{ .fd = -1, .events = 0, .revents = 0 };
            }
        }

        const ready = try posix.poll(&descriptors, timeout_ms);
        std.debug.assert(ready <= descriptors.len);
        var index: usize = 0;
        while (index < self.clients.len) : (index += 1) {
            if (self.clients[index] == null) continue;
            const events = descriptors[index].revents;
            if (events & (posix.POLL.HUP | poll_rdhup | posix.POLL.ERR | posix.POLL.NVAL) != 0) {
                self.closeClient(index);
                continue;
            }
            if (events & posix.POLL.OUT != 0) self.writeClient(index);
            if (self.clients[index] != null and events & posix.POLL.IN != 0) self.readClient(index);
        }

        self.processBufferedRequests();
        self.materializeTreeObservers();
    }

    fn freeClientSlot(self: *const Service) ?usize {
        for (self.clients, 0..) |client, index| if (client == null) return index;
        return null;
    }

    fn closeClient(self: *Service, index: usize) void {
        if (self.clients[index]) |*client| client.deinit(self.allocator);
        self.clients[index] = null;
    }

    fn readClient(self: *Service, index: usize) void {
        const client = if (self.clients[index]) |*value| value else return;
        if (client.outputPending() or client.observe_after != null or client.input_len == client.input.len) return;
        const room = client.input[client.input_len..];
        const result = linux.read(client.fd, room.ptr, room.len);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0 or result > room.len) return self.closeClient(index);
                client.input_len += result;
            },
            .AGAIN, .INTR => {},
            else => self.closeClient(index),
        }
    }

    fn writeClient(self: *Service, index: usize) void {
        const client = if (self.clients[index]) |*value| value else return;
        if (!client.outputPending()) return;
        const bytes = client.output[client.output_offset..client.output_len];
        const result = linux.write(client.fd, bytes.ptr, bytes.len);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0 or result > bytes.len) return self.closeClient(index);
                client.output_offset += result;
                if (!client.outputPending()) client.resetOutput();
            },
            .AGAIN, .INTR => {},
            .PIPE, .CONNRESET => self.closeClient(index),
            else => self.closeClient(index),
        }
    }

    fn processBufferedRequests(self: *Service) void {
        var index: usize = 0;
        while (index < self.clients.len) : (index += 1) {
            while (self.clients[index]) |*client| {
                if (client.outputPending() or client.observe_after != null or
                    client.input_len < protocol.header_bytes)
                    break;
                var header_bytes: [protocol.header_bytes]u8 = undefined;
                @memcpy(&header_bytes, client.input[0..protocol.header_bytes]);
                const header = protocol.decodeHeader(&header_bytes) catch {
                    self.closeClient(index);
                    break;
                };
                if (header.payload_len > protocol.maximum_request_payload_bytes) {
                    self.closeClient(index);
                    break;
                }
                const frame_bytes = protocol.header_bytes + @as(usize, header.payload_len);
                if (frame_bytes > client.input.len) {
                    self.closeClient(index);
                    break;
                }
                if (client.input_len < frame_bytes) break;

                var payload_storage: [protocol.maximum_request_payload_bytes]u8 = undefined;
                @memcpy(payload_storage[0..header.payload_len], client.input[protocol.header_bytes..frame_bytes]);
                const remaining = client.input_len - frame_bytes;
                std.mem.copyForwards(u8, client.input[0..remaining], client.input[frame_bytes..client.input_len]);
                client.input_len = remaining;

                const keep = self.handleFrame(
                    index,
                    client,
                    header.kind,
                    payload_storage[0..header.payload_len],
                );
                if (!keep or self.clients[index] == null) break;
            }
        }
    }

    fn handleFrame(
        self: *Service,
        index: usize,
        client: *Client,
        kind: protocol.Kind,
        payload: []const u8,
    ) bool {
        if (!client.welcomed) {
            if (kind != .hello or payload.len != protocol.payload_bytes.hello) {
                self.closeClient(index);
                return false;
            }
            client.welcomed = true;
            self.queueStatus(client, .welcome) catch {
                self.closeClient(index);
                return false;
            };
            return true;
        }

        switch (kind) {
            .status => {
                if (payload.len != 0) {
                    self.closeClient(index);
                    return false;
                }
                self.queueStatus(client, .status_snapshot) catch {
                    self.closeClient(index);
                    return false;
                };
            },
            .observe_tree => {
                const request = protocol.decodeObserveTree(payload) catch {
                    self.closeClient(index);
                    return false;
                };
                const revision = self.server.treeRevision();
                if (request.after_revision > revision) {
                    self.closeClient(index);
                    return false;
                }
                if (request.after_revision == 0 or revision > request.after_revision) {
                    self.queueTree(client) catch {
                        self.closeClient(index);
                        return false;
                    };
                } else client.observe_after = request.after_revision;
            },
            .create_session => {
                const request = protocol.decodeCreateSession(payload) catch
                    return self.queueMalformed(index, client, kind, 0, 0);
                const id = self.server.createSession(request.name) catch |failure| {
                    const code: protocol.ResultCode = switch (failure) {
                        error.InvalidName => .malformed,
                        error.NameExists => .name_exists,
                        error.Capacity => .session_capacity,
                        error.OutOfMemory, error.IdentityExhausted => .internal,
                    };
                    return self.queueResult(index, client, kind, code, 0, 0);
                };
                return self.queueResult(index, client, kind, .ok, id, 0);
            },
            .close_session => {
                const id = protocol.decodeSessionIdentity(payload) catch
                    return self.queueMalformed(index, client, kind, 0, 0);
                if (!self.server.closeSession(id))
                    return self.queueResult(index, client, kind, .session_not_found, id, 0);
                return self.queueResult(index, client, kind, .ok, id, 0);
            },
            .create_instance => {
                const request = protocol.decodeCreateInstance(payload) catch
                    return self.queueMalformed(index, client, kind, 0, 0);
                const id = self.server.createInstance(
                    request.session_id,
                    self.io,
                    self.inherited_environment,
                    .{
                        .shell = request.shell,
                        .command = request.command,
                        .cwd = request.cwd,
                        .rows = request.rows,
                        .columns = request.columns,
                        .history_rows = request.history_rows,
                    },
                ) catch |failure| {
                    const code: protocol.ResultCode = switch (failure) {
                        error.SessionNotFound => .session_not_found,
                        error.Capacity => .instance_capacity,
                        error.OutOfMemory, error.IdentityExhausted => .internal,
                        else => .create_failed,
                    };
                    return self.queueResult(index, client, kind, code, request.session_id, 0);
                };
                return self.queueResult(index, client, kind, .ok, request.session_id, id);
            },
            .close_instance => {
                const identity = protocol.decodeInstanceIdentity(payload) catch
                    return self.queueMalformed(index, client, kind, 0, 0);
                if (self.server.instanceCount(identity.session_id) == null)
                    return self.queueResult(index, client, kind, .session_not_found, identity.session_id, identity.instance_id);
                if (!self.server.closeInstance(identity.session_id, identity.instance_id))
                    return self.queueResult(index, client, kind, .instance_not_found, identity.session_id, identity.instance_id);
                return self.queueResult(index, client, kind, .ok, identity.session_id, identity.instance_id);
            },
            .attach_instance => return self.handoffAttach(index, client, payload),
            else => {
                self.closeClient(index);
                return false;
            },
        }
        return true;
    }

    fn handoffAttach(self: *Service, index: usize, client: *Client, payload: []const u8) bool {
        const identity = protocol.decodeInstanceIdentity(payload) catch
            return self.queueMalformed(index, client, .attach_instance, 0, 0);

        self.server.adoptClient(
            identity.session_id,
            identity.instance_id,
            client.fd,
            client.input[0..client.input_len],
        ) catch |failure| {
            const code: protocol.ResultCode = switch (failure) {
                error.SessionNotFound => .session_not_found,
                error.InstanceNotFound => .instance_not_found,
                error.ClientCapacity => .unavailable,
                else => .internal,
            };
            return self.queueResult(index, client, .attach_instance, code, identity.session_id, identity.instance_id);
        };

        client.releaseTransferred(self.allocator);
        self.clients[index] = null;
        return false;
    }

    fn queueMalformed(
        self: *Service,
        index: usize,
        client: *Client,
        kind: protocol.Kind,
        session_id: u64,
        instance_id: u64,
    ) bool {
        return self.queueResult(index, client, kind, .malformed, session_id, instance_id);
    }

    fn queueResult(
        self: *Service,
        index: usize,
        client: *Client,
        kind: protocol.Kind,
        code: protocol.ResultCode,
        session_id: u64,
        instance_id: u64,
    ) bool {
        var payload: [protocol.payload_bytes.result]u8 = undefined;
        protocol.encodeResult(&payload, .{
            .request_kind = kind,
            .code = code,
            .session_id = session_id,
            .instance_id = instance_id,
            .tree_revision = self.server.treeRevision(),
        }) catch {
            self.closeClient(index);
            return false;
        };
        queueFrame(client, .result, &payload) catch {
            self.closeClient(index);
            return false;
        };
        return true;
    }

    fn status(self: *const Service) protocol.Status {
        return .{
            .server_id = self.server.identity(),
            .tree_revision = self.server.treeRevision(),
            .session_count = self.server.sessionCount(),
            .instance_count = self.server.instanceCountTotal(),
        };
    }

    fn queueStatus(self: *Service, client: *Client, kind: protocol.Kind) !void {
        var payload: [protocol.payload_bytes.status_snapshot]u8 = undefined;
        try protocol.encodeStatus(&payload, self.status());
        try queueFrame(client, kind, &payload);
    }

    fn queueTree(self: *Service, client: *Client) !void {
        var session_views_storage: [model.maximum_sessions]model.SessionView = undefined;
        const session_views = self.server.snapshotSessions(&session_views_storage);
        var instance_views_storage: [model.maximum_sessions][model.maximum_instances_per_session]model.InstanceView = undefined;
        var instance_records: [model.maximum_sessions][protocol.maximum_instances_per_session]protocol.InstanceRecord = undefined;
        var session_records: [model.maximum_sessions]protocol.SessionRecord = undefined;

        for (session_views, 0..) |session_view, session_index| {
            const views = self.server.snapshotInstances(
                session_view.id,
                &instance_views_storage[session_index],
                // zig-audit: acknowledge orelse_unreachable
                // reason: snapshotSessions and snapshotInstances run synchronously against the same unchanged borrowed Server catalogue.
            ) orelse unreachable;
            for (views, 0..) |view, instance_index| {
                instance_records[session_index][instance_index] = .{
                    .instance_id = view.id,
                    .state = switch (view.state) {
                        .running => .running,
                        .exited => .exited,
                    },
                };
            }
            session_records[session_index] = .{
                .session_id = session_view.id,
                .name = session_view.name,
                .instances = instance_records[session_index][0..views.len],
            };
        }

        var payload: [protocol.maximum_payload_bytes]u8 = undefined;
        const encoded = try protocol.encodeTreeSnapshot(
            &payload,
            self.status(),
            session_records[0..session_views.len],
        );
        try queueFrame(client, .tree_snapshot, encoded);
        client.observe_after = null;
    }

    fn materializeTreeObservers(self: *Service) void {
        const revision = self.server.treeRevision();
        for (&self.clients, 0..) |*maybe_client, index| {
            const client = if (maybe_client.*) |*value| value else continue;
            const after = client.observe_after orelse continue;
            if (revision <= after or client.outputPending()) continue;
            self.queueTree(client) catch {
                self.closeClient(index);
                continue;
            };
        }
    }
};

// Linux POLLRDHUP is not yet named by the pinned stdlib. Unlike POLLHUP,
// it observes a TCP FIN even while our write half remains open.
const poll_rdhup: i16 = 0x2000;

fn clientPollEvents(client: Client) i16 {
    var events: i16 = posix.POLL.HUP | poll_rdhup | posix.POLL.ERR;
    if (client.outputPending()) {
        events |= posix.POLL.OUT;
    } else if (client.observe_after == null) {
        events |= posix.POLL.IN;
    }
    return events;
}

fn queueFrame(client: *Client, kind: protocol.Kind, payload: []const u8) !void {
    if (client.outputPending() or payload.len > protocol.maximum_payload_bytes)
        return error.OutputBusy;
    const total = protocol.header_bytes + payload.len;
    if (total > client.output.len) return error.OutputTooSmall;
    var header: [protocol.header_bytes]u8 = undefined;
    try protocol.encodeHeader(&header, .{ .kind = kind, .payload_len = @intCast(payload.len) });
    @memcpy(client.output[0..protocol.header_bytes], &header);
    @memcpy(client.output[protocol.header_bytes..total], payload);
    client.output_len = total;
    client.output_offset = 0;
}

fn configureAdoptedFd(fd: posix.fd_t) error{SocketOptionFailed}!void {
    const status = linux.fcntl(fd, linux.F.GETFL, @as(usize, 0));
    if (linux.errno(status) != .SUCCESS) return error.SocketOptionFailed;
    const nonblocking: usize = @intCast(@as(u32, @bitCast(linux.O{ .NONBLOCK = true })));
    if (linux.errno(linux.fcntl(fd, linux.F.SETFL, @as(usize, @intCast(status)) | nonblocking)) != .SUCCESS)
        return error.SocketOptionFailed;
    const fd_status = linux.fcntl(fd, linux.F.GETFD, @as(usize, 0));
    if (linux.errno(fd_status) != .SUCCESS) return error.SocketOptionFailed;
    if (linux.errno(linux.fcntl(fd, linux.F.SETFD, @as(usize, @intCast(fd_status)) | linux.FD_CLOEXEC)) != .SUCCESS)
        return error.SocketOptionFailed;
}

fn closeFd(fd: posix.fd_t) void {
    const result = linux.close(fd);
    const errno = linux.errno(result);
    std.debug.assert(errno == .SUCCESS or errno == .INTR);
}

const TestFrame = struct {
    kind: protocol.Kind,
    payload: []u8,

    fn deinit(self: *TestFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.* = undefined;
    }
};

const TestPeer = struct {
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    incoming: std.ArrayList(u8) = .empty,

    fn adopt(allocator: std.mem.Allocator, service: *Service) !TestPeer {
        var pair: [2]posix.fd_t = undefined;
        const result = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &pair);
        if (posix.errno(result) != .SUCCESS) return error.TestSocketCreateFailed;
        errdefer closeFd(pair[0]);
        errdefer closeFd(pair[1]);
        try setNonblocking(pair[1]);
        try service.adoptClient(pair[0], &.{});
        return .{ .allocator = allocator, .fd = pair[1] };
    }

    fn deinit(self: *TestPeer) void {
        if (self.fd >= 0) closeFd(self.fd);
        self.incoming.deinit(self.allocator);
        self.* = undefined;
    }

    fn sendFrame(self: *TestPeer, kind: protocol.Kind, payload: []const u8) !void {
        var header: [protocol.header_bytes]u8 = undefined;
        try protocol.encodeHeader(&header, .{ .kind = kind, .payload_len = @intCast(payload.len) });
        try self.sendRaw(&header);
        try self.sendRaw(payload);
    }

    fn sendRaw(self: *TestPeer, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const result = linux.write(self.fd, bytes[offset..].ptr, bytes.len - offset);
            switch (linux.errno(result)) {
                .SUCCESS => {
                    if (result == 0 or result > bytes.len - offset) return error.TestSocketWriteFailed;
                    offset += result;
                },
                .INTR => continue,
                // zig-audit: acknowledge empty_catch
                // reason: This nonblocking test peer treats yield as a scheduling hint and retries the actual write; a refused hint loses no stream data.
                .AGAIN => std.Thread.yield() catch {},
                else => return error.TestSocketWriteFailed,
            }
        }
    }

    fn readAvailable(self: *TestPeer) !void {
        var scratch: [4096]u8 = undefined;
        while (true) {
            const result = linux.read(self.fd, &scratch, scratch.len);
            switch (linux.errno(result)) {
                .SUCCESS => {
                    if (result == 0) return error.TestPeerClosed;
                    if (result > scratch.len) return error.TestSocketReadFailed;
                    try self.incoming.appendSlice(self.allocator, scratch[0..result]);
                },
                .INTR => continue,
                .AGAIN => return,
                else => return error.TestSocketReadFailed,
            }
        }
    }

    fn popControlFrame(self: *TestPeer) !?TestFrame {
        if (self.incoming.items.len < protocol.header_bytes) return null;
        var header_bytes: [protocol.header_bytes]u8 = undefined;
        @memcpy(&header_bytes, self.incoming.items[0..protocol.header_bytes]);
        const header = try protocol.decodeHeader(&header_bytes);
        const frame_bytes = protocol.header_bytes + @as(usize, header.payload_len);
        if (self.incoming.items.len < frame_bytes) return null;
        const payload = try self.allocator.dupe(u8, self.incoming.items[protocol.header_bytes..frame_bytes]);
        self.consume(frame_bytes);
        return .{ .kind = header.kind, .payload = payload };
    }

    fn consume(self: *TestPeer, count: usize) void {
        std.debug.assert(count <= self.incoming.items.len);
        const remaining = self.incoming.items.len - count;
        std.mem.copyForwards(u8, self.incoming.items[0..remaining], self.incoming.items[count..]);
        self.incoming.shrinkRetainingCapacity(remaining);
    }
};

fn setNonblocking(fd: posix.fd_t) !void {
    const status = linux.fcntl(fd, linux.F.GETFL, @as(usize, 0));
    if (linux.errno(status) != .SUCCESS) return error.TestSocketConfigureFailed;
    const nonblocking: usize = @intCast(@as(u32, @bitCast(linux.O{ .NONBLOCK = true })));
    if (linux.errno(linux.fcntl(fd, linux.F.SETFL, @as(usize, @intCast(status)) | nonblocking)) != .SUCCESS)
        return error.TestSocketConfigureFailed;
}

fn awaitControlFrame(peer: *TestPeer, service: *Service) !TestFrame {
    var turns: usize = 0;
    while (turns < 10_000) : (turns += 1) {
        try peer.readAvailable();
        if (try peer.popControlFrame()) |frame| return frame;
        try service.turn(1);
    }
    return error.TestTimeout;
}

fn handshakeControl(peer: *TestPeer, service: *Service) !protocol.Status {
    try peer.sendFrame(.hello, &.{});
    var frame = try awaitControlFrame(peer, service);
    defer frame.deinit(peer.allocator);
    try std.testing.expectEqual(protocol.Kind.welcome, frame.kind);
    return protocol.decodeStatus(frame.payload);
}

test "control service creates empty Session before explicit Instance creation" {
    const server = try model.Server.init(std.testing.allocator, 0x51);
    defer server.deinit();
    var service = Service.init(std.testing.allocator, std.testing.io, std.testing.environ, server);
    defer service.deinit();
    var peer = try TestPeer.adopt(std.testing.allocator, &service);
    defer peer.deinit();

    const welcome = try handshakeControl(&peer, &service);
    try std.testing.expectEqual(@as(u16, 0), welcome.session_count);
    try std.testing.expectEqual(@as(u16, 0), welcome.instance_count);

    var create_storage: [128]u8 = undefined;
    const create = try protocol.encodeCreateSession(&create_storage, .{ .name = "work" });
    try peer.sendFrame(.create_session, create);
    var created = try awaitControlFrame(&peer, &service);
    defer created.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.Kind.result, created.kind);
    const result = try protocol.decodeResult(created.payload);
    try std.testing.expectEqual(protocol.ResultCode.ok, result.code);
    try std.testing.expectEqual(@as(u64, 1), result.session_id);
    try std.testing.expectEqual(@as(u64, 0), result.instance_id);
    try std.testing.expectEqual(@as(u16, 0), server.instanceCount(result.session_id).?);

    var observe: [protocol.payload_bytes.observe_tree]u8 = undefined;
    protocol.encodeObserveTree(&observe, .{ .after_revision = 0 });
    try peer.sendFrame(.observe_tree, &observe);
    var tree = try awaitControlFrame(&peer, &service);
    defer tree.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.Kind.tree_snapshot, tree.kind);
    var decoder = try protocol.TreeDecoder.init(tree.payload);
    const session = (try decoder.nextSession()).?;
    try std.testing.expectEqual(result.session_id, session.session_id);
    try std.testing.expectEqualStrings("work", session.name);
    try std.testing.expectEqual(@as(u16, 0), session.instance_count);
    try std.testing.expect((try decoder.nextSession()) == null);
}

test "tree observer wakes on explicit Instance creation under its Session" {
    const server = try model.Server.init(std.testing.allocator, 0x52);
    defer server.deinit();
    const work = try server.createSession("work");
    var service = Service.init(std.testing.allocator, std.testing.io, std.testing.environ, server);
    defer service.deinit();
    var observer = try TestPeer.adopt(std.testing.allocator, &service);
    defer observer.deinit();
    const observer_welcome = try handshakeControl(&observer, &service);
    try std.testing.expectEqual(server.identity(), observer_welcome.server_id);

    var observe: [protocol.payload_bytes.observe_tree]u8 = undefined;
    protocol.encodeObserveTree(&observe, .{ .after_revision = server.treeRevision() });
    try observer.sendFrame(.observe_tree, &observe);
    var settle: usize = 0;
    while (settle < 4) : (settle += 1) try service.turn(0);
    try observer.readAvailable();
    try std.testing.expectEqual(@as(usize, 0), observer.incoming.items.len);

    var control = try TestPeer.adopt(std.testing.allocator, &service);
    defer control.deinit();
    const control_welcome = try handshakeControl(&control, &service);
    try std.testing.expectEqual(server.identity(), control_welcome.server_id);
    var create_storage: [protocol.maximum_request_payload_bytes]u8 = undefined;
    const create = try protocol.encodeCreateInstance(&create_storage, .{
        .session_id = work,
        .shell = "/bin/sh",
        .command = "cat",
        .rows = 4,
        .columns = 20,
        .history_rows = 32,
    });
    try control.sendFrame(.create_instance, create);
    var created = try awaitControlFrame(&control, &service);
    defer created.deinit(std.testing.allocator);
    const result = try protocol.decodeResult(created.payload);
    try std.testing.expectEqual(protocol.ResultCode.ok, result.code);
    try std.testing.expectEqual(work, result.session_id);
    try std.testing.expectEqual(@as(u64, 1), result.instance_id);

    var tree = try awaitControlFrame(&observer, &service);
    defer tree.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.Kind.tree_snapshot, tree.kind);
    var decoder = try protocol.TreeDecoder.init(tree.payload);
    const session = (try decoder.nextSession()).?;
    try std.testing.expectEqual(work, session.session_id);
    try std.testing.expectEqual(@as(u16, 1), session.instance_count);
    const instance = try decoder.nextInstance();
    try std.testing.expectEqual(result.instance_id, instance.instance_id);
    try std.testing.expectEqual(protocol.InstanceState.running, instance.state);
    try std.testing.expect((try decoder.nextSession()) == null);
}

test "exact attachment queues ready before pipelined terminal interaction" {
    const server = try model.Server.init(std.testing.allocator, 0x53);
    defer server.deinit();
    const work = try server.createSession("work");
    const instance_id = try server.createInstance(work, std.testing.io, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "cat",
        .rows = 4,
        .columns = 20,
        .history_rows = 32,
    });
    var service = Service.init(std.testing.allocator, std.testing.io, std.testing.environ, server);
    defer service.deinit();
    var peer = try TestPeer.adopt(std.testing.allocator, &service);
    defer peer.deinit();
    const peer_welcome = try handshakeControl(&peer, &service);
    try std.testing.expectEqual(server.identity(), peer_welcome.server_id);

    var identity: [protocol.payload_bytes.instance_identity]u8 = undefined;
    try protocol.encodeInstanceIdentity(&identity, .{ .session_id = work, .instance_id = instance_id });
    try peer.sendFrame(.attach_instance, &identity);
    var pipelined: [instance_protocol.header_bytes]u8 = undefined;
    try instance_protocol.encodeHeader(&pipelined, .{ .kind = .interaction_state, .payload_len = 0 });
    try peer.sendRaw(&pipelined);

    var control_turns: usize = 0;
    while (control_turns < 8) : (control_turns += 1) try service.turn(0);

    var ready: ?TestFrame = null;
    var turns: usize = 0;
    while (turns < 10_000 and ready == null) : (turns += 1) {
        try peer.readAvailable();
        ready = try peer.popControlFrame();
        if (ready == null) try server.turnInstance(work, instance_id, 1);
    }
    var attach_ready = ready orelse return error.TestTimeout;
    defer attach_ready.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.Kind.attach_ready, attach_ready.kind);
    const attached = try protocol.decodeAttachReady(attach_ready.payload);
    try std.testing.expectEqual(work, attached.session_id);
    try std.testing.expectEqual(instance_id, attached.instance_id);

    try std.testing.expectEqual(server.identity(), attached.server_id);
    try std.testing.expect(attached.client_id != instance_protocol.no_client);
    var response_header: ?instance_protocol.Header = null;
    turns = 0;
    while (turns < 10_000 and response_header == null) : (turns += 1) {
        try peer.readAvailable();
        if (peer.incoming.items.len >= instance_protocol.header_bytes) {
            response_header = try instance_protocol.decodeHeader(peer.incoming.items[0..instance_protocol.header_bytes]);
            peer.consume(instance_protocol.header_bytes);
            break;
        }
        try server.turnInstance(work, instance_id, 1);
    }
    const header = response_header orelse return error.TestTimeout;
    try std.testing.expectEqual(instance_protocol.Kind.interaction_state_snapshot, header.kind);
    try std.testing.expectEqual(@as(u32, instance_protocol.payload_bytes.interaction_state_snapshot), header.payload_len);
    turns = 0;
    while (peer.incoming.items.len < header.payload_len and turns < 10_000) : (turns += 1) {
        try server.turnInstance(work, instance_id, 1);
        try peer.readAvailable();
    }
    if (peer.incoming.items.len < header.payload_len) return error.TestTimeout;
    const state = try instance_protocol.decodeInteractionStateSnapshot(peer.incoming.items[0..header.payload_len]);
    try std.testing.expect(state.terminal_revision != 0);
    peer.consume(header.payload_len);
}

test "attach identity failure stays on control stream with distinct error" {
    const server = try model.Server.init(std.testing.allocator, 0x54);
    defer server.deinit();
    const work = try server.createSession("work");
    const instance_id = try server.createInstance(work, std.testing.io, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "cat",
        .rows = 2,
        .columns = 8,
    });
    var service = Service.init(std.testing.allocator, std.testing.io, std.testing.environ, server);
    defer service.deinit();
    var peer = try TestPeer.adopt(std.testing.allocator, &service);
    defer peer.deinit();
    const peer_welcome = try handshakeControl(&peer, &service);
    try std.testing.expectEqual(server.identity(), peer_welcome.server_id);

    var identity: [protocol.payload_bytes.instance_identity]u8 = undefined;
    try protocol.encodeInstanceIdentity(&identity, .{ .session_id = work, .instance_id = instance_id + 100 });
    try peer.sendFrame(.attach_instance, &identity);
    var failed = try awaitControlFrame(&peer, &service);
    defer failed.deinit(std.testing.allocator);
    const result = try protocol.decodeResult(failed.payload);
    try std.testing.expectEqual(protocol.ResultCode.instance_not_found, result.code);

    try peer.sendFrame(.status, &.{});
    var status = try awaitControlFrame(&peer, &service);
    defer status.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.Kind.status_snapshot, status.kind);
}

test "failed control adoption retains caller fd ownership" {
    const server = try model.Server.init(std.testing.allocator, 0x55);
    defer server.deinit();
    var service = Service.init(std.testing.allocator, std.testing.io, std.testing.environ, server);
    defer service.deinit();
    var pair: [2]posix.fd_t = undefined;
    const socket_result = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &pair);
    try std.testing.expectEqual(posix.E.SUCCESS, posix.errno(socket_result));
    defer closeFd(pair[0]);
    defer closeFd(pair[1]);
    var oversized: [input_bytes + 1]u8 = @splat(0);
    try std.testing.expectError(error.InitialInputTooLarge, service.adoptClient(pair[0], &oversized));
    const flags = linux.fcntl(pair[0], linux.F.GETFD, @as(usize, 0));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(flags));
}

test "malformed control client closes alone" {
    const server = try model.Server.init(std.testing.allocator, 0x56);
    defer server.deinit();
    var service = Service.init(std.testing.allocator, std.testing.io, std.testing.environ, server);
    defer service.deinit();

    var good = try TestPeer.adopt(std.testing.allocator, &service);
    defer good.deinit();
    const good_welcome = try handshakeControl(&good, &service);
    try std.testing.expectEqual(server.identity(), good_welcome.server_id);

    var bad = try TestPeer.adopt(std.testing.allocator, &service);
    defer bad.deinit();
    var malformed: [protocol.header_bytes]u8 = undefined;
    try protocol.encodeHeader(&malformed, .{ .kind = .hello, .payload_len = 0 });
    malformed[6] = 1;
    try bad.sendRaw(&malformed);
    var turns: usize = 0;
    while (turns < 8) : (turns += 1) try service.turn(0);
    try std.testing.expectError(error.TestPeerClosed, bad.readAvailable());

    try good.sendFrame(.status, &.{});
    var status = try awaitControlFrame(&good, &service);
    defer status.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.Kind.status_snapshot, status.kind);
}

test "unserviced control client cannot pace Instance lifecycle" {
    const server = try model.Server.init(std.testing.allocator, 0x57);
    defer server.deinit();
    const work = try server.createSession("work");
    const instance_id = try server.createInstance(work, std.testing.io, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "exit 0",
        .rows = 2,
        .columns = 8,
    });
    var service = Service.init(std.testing.allocator, std.testing.io, std.testing.environ, server);
    defer service.deinit();
    var peer = try TestPeer.adopt(std.testing.allocator, &service);
    defer peer.deinit();
    const welcome = try handshakeControl(&peer, &service);
    try std.testing.expectEqual(server.identity(), welcome.server_id);

    // Leave a valid control request unread/unserviced while the Instance advances.
    try peer.sendFrame(.status, &.{});

    var turns: usize = 0;
    while (turns < 10_000 and server.instanceState(work, instance_id).? == .running) : (turns += 1)
        try server.turnInstance(work, instance_id, 1);
    try std.testing.expect(server.instanceState(work, instance_id).? == .exited);
    try std.testing.expectEqual(work, server.findSessionByName("work").?);
}

test "control Service deinit leaves borrowed Server usable" {
    const server = try model.Server.init(std.testing.allocator, 0x58);
    defer server.deinit();
    const first = try server.createSession("first");
    {
        var service = Service.init(std.testing.allocator, std.testing.io, std.testing.environ, server);
        var peer = try TestPeer.adopt(std.testing.allocator, &service);
        const welcome = try handshakeControl(&peer, &service);
        try std.testing.expectEqual(server.identity(), welcome.server_id);
        peer.deinit();
        service.deinit();
    }
    try std.testing.expectEqual(first, server.findSessionByName("first").?);
    const second = try server.createSession("second");
    try std.testing.expect(second > first);
    try std.testing.expectEqual(@as(u16, 2), server.sessionCount());
}

test "control wait descriptors distinguish input output and parked tree observers" {
    const server = try model.Server.init(std.testing.allocator, 0x59);
    defer server.deinit();
    var service = Service.init(std.testing.allocator, std.testing.io, std.testing.environ, server);
    defer service.deinit();
    var peer = try TestPeer.adopt(std.testing.allocator, &service);
    defer peer.deinit();

    var waits_storage: [Service.maximum_wait_descriptors]Service.WaitDescriptor = undefined;
    var waits = service.snapshotWaitDescriptors(&waits_storage);
    try std.testing.expectEqual(@as(usize, 1), waits.len);
    try std.testing.expect(waits[0].events & posix.POLL.IN != 0);
    try std.testing.expectEqual(@as(i16, 0), waits[0].events & posix.POLL.OUT);

    try peer.sendFrame(.hello, &.{});
    try service.turn(0);
    waits = service.snapshotWaitDescriptors(&waits_storage);
    try std.testing.expect(waits[0].events & posix.POLL.OUT != 0);
    try std.testing.expectEqual(@as(i16, 0), waits[0].events & posix.POLL.IN);

    var welcome = try awaitControlFrame(&peer, &service);
    defer welcome.deinit(std.testing.allocator);
    try std.testing.expectEqual(protocol.Kind.welcome, welcome.kind);
    waits = service.snapshotWaitDescriptors(&waits_storage);
    try std.testing.expect(waits[0].events & posix.POLL.IN != 0);
    try std.testing.expectEqual(@as(i16, 0), waits[0].events & posix.POLL.OUT);

    var observe: [protocol.payload_bytes.observe_tree]u8 = undefined;
    protocol.encodeObserveTree(&observe, .{ .after_revision = server.treeRevision() });
    try peer.sendFrame(.observe_tree, &observe);
    try service.turn(0);
    waits = service.snapshotWaitDescriptors(&waits_storage);
    try std.testing.expectEqual(@as(usize, 1), waits.len);
    try std.testing.expectEqual(@as(i16, 0), waits[0].events & posix.POLL.IN);
    try std.testing.expectEqual(@as(i16, 0), waits[0].events & posix.POLL.OUT);
    try std.testing.expect(waits[0].events & poll_rdhup != 0);
    try std.testing.expect(waits[0].events & posix.POLL.HUP != 0);
    try std.testing.expect(waits[0].events & posix.POLL.ERR != 0);
}
