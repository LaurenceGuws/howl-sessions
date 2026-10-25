//! Importing proof of the public opaque Server owner and const observation API.
const std = @import("std");
const model = @import("server");

test "Server is the opaque owner, with mutations requiring mutable authority" {
    try std.testing.expect(@typeInfo(model.Server) == .@"opaque");
    const init_result = @typeInfo(@TypeOf(model.Server.init)).@"fn".return_type.?;
    try std.testing.expectEqual(*model.Server, @typeInfo(init_result).error_union.payload);
    inline for (.{
        model.Server.deinit,
        model.Server.createSession,
        model.Server.closeSession,
        model.Server.createInstance,
        model.Server.closeInstance,
        model.Server.adoptClient,
        model.Server.turnInstance,
    }) |method| {
        try std.testing.expectEqual(*model.Server, @typeInfo(@TypeOf(method)).@"fn".param_types[0].?);
    }
    inline for (.{
        model.Server.identity,
        model.Server.sessionCount,
        model.Server.treeRevision,
        model.Server.instanceCountTotal,
        model.Server.turnInstanceCount,
        model.Server.instanceRequiresTurn,
        model.Server.instanceWaitDescriptor,
        model.Server.instanceCount,
        model.Server.instanceState,
        model.Server.findSessionByName,
        model.Server.snapshotSessions,
        model.Server.snapshotInstances,
    }) |method| {
        try std.testing.expectEqual(*const model.Server, @typeInfo(@TypeOf(method)).@"fn".param_types[0].?);
    }
    try std.testing.expectEqual([]const u8, @FieldType(model.SessionView, "name"));
}

test "one Server allocation supports direct mutations and const copied observations" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const server = try model.Server.init(counting.allocator(), 42);
    defer server.deinit();
    try std.testing.expectEqual(@as(usize, 1), counting.alloc_index);
    const view: *const model.Server = server;
    try std.testing.expectEqual(@as(u16, 0), view.sessionCount());
    try std.testing.expectEqual(@as(u64, 1), view.treeRevision());
    const sid = try server.createSession("from-owner");
    // Session records stay lazily allocated and internal; the second allocation
    // is the label, not another opaque wrapper/owner.
    try std.testing.expectEqual(@as(usize, 3), counting.alloc_index);
    var storage: [model.maximum_sessions]model.SessionView = undefined;
    const sessions = view.snapshotSessions(&storage);
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqual(sid, sessions[0].id);
    try std.testing.expectEqualStrings("from-owner", sessions[0].name);
    try std.testing.expectEqual(@as(u64, 2), view.treeRevision());
    try std.testing.expect(server.closeSession(sid));
    try std.testing.expectEqual(@as(u16, 0), view.sessionCount());
}
