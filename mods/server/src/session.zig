//! One orchestration Session containing zero or more concrete terminal Instances.
//!
//! Session identity survives individual Instance exit/removal. Launch policy belongs
//! to Instance creation; Session itself knows no shell, command, cwd or geometry.

const std = @import("std");
const howl_instance = @import("howl_instance");
const instance_service = @import("server_terminal_service");

/// Nonzero Instance identity within one Session lifetime.
pub const InstanceId = u64;
/// Bound on simultaneously retained Instances in one Session.
pub const maximum_instances: usize = 16;

/// Copied running or exited state of a retained Instance.
pub const InstanceState = enum { running, exited };

/// Reports whether a service turn changed retained lifecycle state.
pub const TurnOutcome = struct { state_changed: bool = false };

/// Copied Instance identity and lifecycle state.
pub const InstanceView = struct {
    id: InstanceId,
    state: InstanceState,
};

const InstanceRecord = struct {
    id: InstanceId,
    value: *howl_instance.Instance,
    service: instance_service.Service,
    state: InstanceState = .running,

    fn deinit(self: *InstanceRecord) void {
        self.service.deinit();
        howl_instance.deinit(self.value);
        self.* = undefined;
    }
};

/// Reports allocation, Instance/service construction, capacity or identity exhaustion.
pub const CreateInstanceError = std.mem.Allocator.Error || howl_instance.InitError || instance_service.Service.InitError || error{
    Capacity,
    IdentityExhausted,
};

// Internal typed owner, reachable only through Server's private records.
/// Server-private typed owner of a copied name and bounded Instance records.
pub const Session = struct {
    allocator: std.mem.Allocator,
    id: u64,
    name: []u8,
    next_instance_id: InstanceId = 1,
    instances: [maximum_instances]?InstanceRecord = @splat(null),
    count: u16 = 0,

    /// Allocates an empty Session and copies its validated name.
    pub fn init(allocator: std.mem.Allocator, id: u64, name: []const u8) !*Session {
        std.debug.assert(id != 0);
        @import("server_protocol").validateSessionName(name) catch return error.InvalidName;
        const storage = try allocator.create(Session);
        errdefer allocator.destroy(storage);
        storage.* = .{
            .allocator = allocator,
            .id = id,
            .name = try allocator.dupe(u8, name),
        };
        return storage;
    }

    /// Releases nested services and Instances, the copied name and this allocation.
    pub fn deinit(self: *Session) void {
        var index = self.instances.len;
        while (index != 0) {
            index -= 1;
            if (self.instances[index]) |*record| {
                record.deinit();
                self.instances[index] = null;
            }
        }
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    /// Returns the number of retained Instances.
    pub fn instanceCount(self: *const Session) u16 {
        return self.count;
    }

    /// Constructs and retains one explicitly launched Instance and its service.
    pub fn createInstance(
        self: *Session,
        io: std.Io,
        inherited_environment: std.process.Environ,
        launch: howl_instance.Launch,
    ) CreateInstanceError!InstanceId {
        if (self.count == self.instances.len) return error.Capacity;
        if (self.next_instance_id == 0) return error.IdentityExhausted;
        // zig-audit: acknowledge orelse_unreachable
        // reason: The maintained count is checked below the fixed Instance slot capacity before this synchronous free-slot lookup.
        const slot = self.freeSlot() orelse unreachable;
        const owned = try howl_instance.init(self.allocator, inherited_environment, launch);
        errdefer howl_instance.deinit(owned);
        var service = try instance_service.Service.init(self.allocator, io, owned);
        errdefer service.deinit();

        const id = self.next_instance_id;
        self.next_instance_id = advanceIdentity(id) catch return error.IdentityExhausted;
        self.instances[slot] = .{ .id = id, .value = owned, .service = service };
        self.count += 1;
        return id;
    }

    /// Releases a selected Instance and reports whether it existed.
    pub fn closeInstance(self: *Session, id: InstanceId) bool {
        const index = self.findInstanceIndex(id) orelse return false;
        if (self.instances[index]) |*record| record.deinit();
        self.instances[index] = null;
        self.count -= 1;
        return true;
    }

    /// Returns copied lifecycle state, or null for an unknown Instance.
    pub fn instanceState(self: *const Session, instance_id: InstanceId) ?InstanceState {
        const index = self.findInstanceIndex(instance_id) orelse return null;
        return self.instances[index].?.state;
    }

    /// Returns pending-work status, or null for an unknown Instance.
    pub fn instanceRequiresTurn(self: *const Session, instance_id: InstanceId) ?bool {
        const index = self.findInstanceIndex(instance_id) orelse return null;
        const record = self.instances[index].?;
        if (record.state == .exited)
            return record.service.hasRetainedWork();
        return record.service.requiresTurnWithoutPtyReadiness();
    }

    /// Counts Instances requiring service work without new PTY readiness.
    pub fn turnInstanceCount(self: *const Session) u16 {
        var count: u16 = 0;
        for (self.instances) |maybe_record| {
            const record = maybe_record orelse continue;
            const required = if (record.state == .exited)
                record.service.hasRetainedWork()
            else
                record.service.requiresTurnWithoutPtyReadiness();
            if (required) count += 1;
        }
        return count;
    }

    /// Borrows a running Instance's wait descriptor, or null when absent/exited.
    pub fn instanceWaitDescriptor(
        self: *const Session,
        instance_id: InstanceId,
    ) error{NotStarted}!?std.posix.fd_t {
        const index = self.findInstanceIndex(instance_id) orelse return null;
        const record = self.instances[index].?;
        if (record.state == .exited) return null;
        return try record.service.waitDescriptor();
    }

    /// Copies ordered Instance facts into caller-owned bounded storage.
    pub fn snapshotInstances(self: *const Session, output: *[maximum_instances]InstanceView) []const InstanceView {
        var count: usize = 0;
        for (self.instances) |maybe_record| {
            const record = maybe_record orelse continue;
            var insert = count;
            while (insert != 0 and output[insert - 1].id > record.id) : (insert -= 1)
                output[insert] = output[insert - 1];
            output[insert] = .{ .id = record.id, .state = record.state };
            count += 1;
        }
        std.debug.assert(count == self.count);
        return output[0..count];
    }

    /// Reports service adoption failure or a missing Instance.
    pub const AdoptClientError = instance_service.Service.AdoptError || error{InstanceNotFound};

    /// Transfers a connected stream to an Instance service only on success.
    pub fn adoptClient(
        self: *Session,
        instance_id: InstanceId,
        fd: std.posix.fd_t,
        initial_input: []const u8,
        context: instance_service.AttachContext,
    ) AdoptClientError!void {
        const index = self.findInstanceIndex(instance_id) orelse return error.InstanceNotFound;
        return self.instances[index].?.service.adoptClient(fd, initial_input, context);
    }

    /// Reports service-turn failure or a missing Instance.
    pub const TurnInstanceError = instance_service.Service.TurnError || error{InstanceNotFound};

    /// Services one Instance and reports its first transition to exited.
    pub fn turnInstance(self: *Session, instance_id: InstanceId, timeout_ms: i32) TurnInstanceError!TurnOutcome {
        const index = self.findInstanceIndex(instance_id) orelse return error.InstanceNotFound;
        const record = &self.instances[index].?;
        try record.service.turn(timeout_ms);
        if (record.state == .running and record.service.lifecycle().child_exited) {
            record.state = .exited;
            return .{ .state_changed = true };
        }
        return .{};
    }

    fn freeSlot(self: *const Session) ?usize {
        for (self.instances, 0..) |record, index| if (record == null) return index;
        return null;
    }

    fn findInstanceIndex(self: *const Session, id: InstanceId) ?usize {
        for (self.instances, 0..) |maybe_record, index| {
            const record = maybe_record orelse continue;
            if (record.id == id) return index;
        }
        return null;
    }
};

test "Instance removal leaves its Session alive and empty" {
    const session = try Session.init(std.testing.allocator, 11, "work");
    defer session.deinit();

    const first = try session.createInstance(std.testing.io, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "exit 0",
        .rows = 4,
        .columns = 12,
    });
    try std.testing.expectEqual(@as(InstanceId, 1), first);
    try std.testing.expectEqual(@as(u16, 1), session.instanceCount());
    try std.testing.expect(session.closeInstance(first));
    try std.testing.expectEqual(@as(u16, 0), session.instanceCount());
    try std.testing.expectEqual(@as(u64, 11), session.id);
    try std.testing.expectEqualStrings("work", session.name);

    const second = try session.createInstance(std.testing.io, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "exit 0",
        .rows = 4,
        .columns = 12,
    });
    try std.testing.expectEqual(@as(InstanceId, 2), second);
}

test "failed Instance construction mutates no Session identity or count" {
    const session = try Session.init(std.testing.allocator, 13, "work");
    defer session.deinit();
    try std.testing.expectError(
        error.InvalidDimensions,
        session.createInstance(std.testing.io, std.testing.environ, .{
            .shell = "/bin/sh",
            .command = "exit 0",
            .rows = 0,
            .columns = 12,
        }),
    );
    try std.testing.expectEqual(@as(u16, 0), session.instanceCount());
    const first = try session.createInstance(std.testing.io, std.testing.environ, .{
        .shell = "/bin/sh",
        .command = "exit 0",
        .rows = 4,
        .columns = 12,
    });
    try std.testing.expectEqual(@as(InstanceId, 1), first);
}

fn advanceIdentity(current: u64) error{IdentityExhausted}!u64 {
    if (current == std.math.maxInt(u64)) return error.IdentityExhausted;
    const next = current + 1;
    if (next == 0) return error.IdentityExhausted;
    return next;
}

test "Session creation has zero Instances and no launch policy" {
    const session = try Session.init(std.testing.allocator, 7, "work");
    defer session.deinit();
    try std.testing.expectEqual(@as(u16, 0), session.instanceCount());
    try std.testing.expectEqualStrings("work", session.name);
}
