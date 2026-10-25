//! Coherent terminal interaction state for mode-aware native clients.

const protocol = @import("server_protocol").terminal;
const client = @import("terminal_owner");

/// Reports connection, payload, or interaction-state framing failures.
pub const Error = client.Error || protocol.PayloadError || error{
    UnexpectedFrame,
    ServerRejected,
};

/// Fetches one coherent current terminal interaction-state snapshot.
pub fn get(connection: *client.Connection) Error!protocol.InteractionStateSnapshot {
    try connection.send(.interaction_state, &.{});
    var completed = false;
    defer if (!completed) client.retire(connection);
    var frame = try connection.receive();
    defer frame.deinit();
    if (frame.kind == .result) {
        const result = try protocol.decodeResult(frame.payload);
        if (result.request_kind != .interaction_state or result.code == .ok) return error.UnexpectedFrame;
        completed = true;
        return error.ServerRejected;
    }
    if (frame.kind != .interaction_state_snapshot) return error.UnexpectedFrame;
    const state = try protocol.decodeInteractionStateSnapshot(frame.payload);
    completed = true;
    return state;
}
