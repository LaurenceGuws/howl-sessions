//! Compiles the client public graph without Server, Instance, PTY, VT or Render imports.
const std = @import("std");
const client = @import("server_client");
const protocol = @import("server_protocol");

test "client-only public graph owns no canonical process or runtime" {
    std.testing.refAllDecls(client);
    std.testing.refAllDecls(client.terminal);
    try std.testing.expect(client.protocol == protocol);
    try std.testing.expect(client.terminal.protocol == protocol.terminal);
    inline for (.{ "Runtime", "Server", "Session", "instance", "pty", "render" }) |name| {
        try std.testing.expect(!@hasDecl(client, name));
        try std.testing.expect(!@hasDecl(client.terminal, name));
    }
}

test "public connection authority is opaque and has no raw constructor or storage" {
    try std.testing.expect(@typeInfo(client.Connection) == .@"opaque");
    try std.testing.expect(@typeInfo(client.terminal.Connection) == .@"opaque");
    inline for (.{ "State", "Stream", "Frame", "Attached", "connectTransport", "create", "stateOf" }) |name|
        try std.testing.expect(!@hasDecl(client, name));
    try std.testing.expect(!@hasDecl(client.Connection, "attachInstance"));
    inline for (.{ "create", "stateOf", "retire", "ownerAllocator", "stream", "allocator" }) |name|
        try std.testing.expect(!@hasDecl(client.terminal, name));
}

test "byte capability is opaque caller storage without native transport construction" {
    try std.testing.expect(@typeInfo(client.terminal.byte.ByteClient) == .@"opaque");
    inline for (.{ "State", "Stream", "Connection", "stateOf", "allocator", "socket" }) |name|
        try std.testing.expect(!@hasDecl(client.terminal.byte, name));
}
