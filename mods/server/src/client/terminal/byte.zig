//! Caller-driven Server attachment transactions over borrowed byte buffers.
//! No socket, allocator, OS resource, clock, worker or application runtime.
const std = @import("std");
const server = @import("server_protocol");
/// Exact Server terminal wire vocabulary used by typed starts and events.
pub const protocol = server.terminal;
const p = protocol;

/// Construction, admission, framing and transaction failures. Receive failures
/// retire the client; rejected starts leave state and caller buffers untouched.
pub const Error = p.HeaderError || p.PayloadError || error{
    InvalidBuffers,
    InvalidInputAlias,
    InvalidState,
    BufferTooSmall,
    OutputTooSmall,
    ResultTooSmall,
    ExpectedAttachReady,
    UnexpectedSnapshotFrame,
    MixedSnapshotBodyEncoding,
    MissingSnapshotBody,
    SnapshotTooLarge,
    SnapshotRevisionMismatch,
    LiveHistoryOffsetMismatch,
    ExpectedControlResult,
    InputRejected,
    ResizeLeaderRejected,
    ResizeResultMismatch,
    MissingControlOperation,
    ExpectedInteractionStateSnapshot,
    TextExtractResultMismatch,
    InvalidTextExtractData,
    ImageResultMismatch,
    ExpectedImageBegin,
    ImageIdentityMismatch,
    InvalidImageData,
    ExpectedImageEnd,
    UnsolicitedFrame,
    TruncatedResponse,
};

/// Caller-owned, mutually disjoint storage. packet/output need at least a
/// header; smaller observation/result capacities fail explicitly when needed.
/// result holds either selected UTF-8 text or one image, never both concurrently.
pub const Buffers = struct {
    packet: []u8,
    outgoing: []u8,
    observation: []u8,
    result: []u8,
};

/// Observation collection is intentionally separate from semantic VT decoding.
/// collect returns the ordinary framed response for rich.decodeFrames; live
/// validates the complete live envelope without decoding terminal payloads.
pub const ObservationMode = enum { collect, live };

/// One immutable terminal image response borrowed from result storage.
pub const Image = struct {
    image_id: u32 = 0,
    generation: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    bytes: []const u8,
};

/// Response boundaries let an embedder validate/project a complete observation
/// before feeding any following bytes. Rejections are complete results, not
/// transport failures; the caller chooses application close/retry policy.
pub const Event = union(enum) {
    progress,
    attached: server.AttachReady,
    observation: ?p.SnapshotBegin,
    result: p.Result,
    outgoing_followup: p.Result,
    interaction: p.InteractionStateSnapshot,
    text: []const u8,
    image: Image,
};

/// feed stops at one response event; the caller retains the unconsumed suffix.
/// An outgoing_followup requires sending outgoing() before continuing receive.
pub const Feed = struct { consumed: usize, event: Event };

/// Fixed, aligned caller storage for the opaque implementation. Its address and
/// all supplied buffers must remain stable until the final use. Reinitializing
/// storage or resetAwaitReady invalidates all previous response borrows.
pub const Storage = struct {
    bytes: [@sizeOf(State)]u8 align(@alignOf(State)) = undefined,
};

/// One caller-serialized ordered attachment; owns no allocation or OS resource.
// zig-audit: acknowledge opaque_type
// reason: Transaction state and buffer bounds are private; callers supply only sized storage and byte buffers.
pub const ByteClient = opaque {
    /// Initializes a closed client without modifying any supplied byte buffer.
    pub fn init(storage: *Storage, buffers: Buffers) Error!*ByteClient {
        try validateBuffers(storage, buffers);
        // zig-audit: acknowledge ptr_cast
        // reason: Storage has exactly State's size and alignment and stays at its caller-owned address.
        const state: *State = @ptrCast(&storage.bytes);
        state.* = .{ .buffers = buffers };
        // zig-audit: acknowledge ptr_cast
        // reason: This exact private State is the only constructor backing ByteClient.
        return @ptrCast(state);
    }

    /// Begins a fresh attachment-ready exchange; invalidates all old borrows.
    pub fn resetAwaitReady(self: *ByteClient) void {
        const s = stateOf(self);
        s.* = .{ .buffers = s.buffers, .phase = .ready };
    }

    /// Stops this logical stream and invalidates staged outgoing bytes.
    pub fn retire(self: *ByteClient) void {
        const s = stateOf(self);
        s.phase = .retired;
        s.output_len = 0;
    }

    /// True when one new ordinary request may be admitted.
    pub fn isIdle(self: *const ByteClient) bool {
        return constStateOf(self).phase == .idle;
    }

    /// Borrows one staged request until the next client mutation.
    pub fn outgoing(self: *const ByteClient) []const u8 {
        const s = constStateOf(self);
        return s.buffers.outgoing[0..s.output_len];
    }

    /// Borrows collected frames, complete only after an observation event.
    /// Bytes remain valid until a new observe/reset or caller buffer mutation.
    pub fn observationBytes(self: *const ByteClient) []const u8 {
        const s = constStateOf(self);
        return s.buffers.observation[0..s.observation_len];
    }

    /// Copies accepted occurrence identity; null before attachment-ready.
    pub fn identity(self: *const ByteClient) ?server.AttachReady {
        return constStateOf(self).ready;
    }

    /// Borrows current image staging; use bytes only after an image event.
    /// A completed image remains held until releaseImage/reset.
    pub fn image(self: *const ByteClient) Image {
        const s = constStateOf(self);
        return .{ .image_id = s.image_id, .generation = s.image_generation, .width = s.image_width, .height = s.image_height, .bytes = s.buffers.result[0..s.image_len] };
    }

    /// Starts ordinary observation collection or the validated live envelope.
    pub fn observe(self: *ByteClient, request: p.Observe, mode: ObservationMode) Error!void {
        const s = stateOf(self);
        try s.requireIdle();
        var payload: [p.payload_bytes.observe]u8 = undefined;
        p.encodeObserve(&payload, request);
        try s.queue(.observe, &payload);
        s.observation_len = 0;
        s.mode = mode;
        s.begin = null;
        s.envelope = .begin;
        s.body_kind = null;
        s.phase = .observation;
    }

    /// Starts committed byte or paste input; UTF-8/UI admission is caller policy.
    pub fn sendBytes(self: *ByteClient, kind: enum { bytes, paste }, bytes: []const u8) Error!void {
        const s = stateOf(self);
        try s.requireIdle();
        if (bytes.len == 0 or bytes.len > p.maximum_request_payload_bytes - 1)
            return error.InvalidPayload;
        try s.validateInput(bytes);
        if (bytes.len + 1 > s.buffers.outgoing.len - p.header_bytes) return error.BufferTooSmall;
        try p.encodeHeader(s.buffers.outgoing[0..p.header_bytes], .{
            .kind = .input,
            .payload_len = @intCast(bytes.len + 1),
        });
        s.buffers.outgoing[p.header_bytes] = @backingInt(switch (kind) {
            .bytes => p.InputKind.bytes,
            .paste => p.InputKind.paste,
        });
        @memcpy(s.buffers.outgoing[p.header_bytes + 1 ..][0..bytes.len], bytes);
        s.output_len = p.header_bytes + 1 + bytes.len;
        s.operation = .input;
        s.phase = .control;
    }

    /// Encodes one typed physical-key input before any output mutation.
    pub fn sendKey(self: *ByteClient, input: p.KeyInput) Error!void {
        var payload: [
            1 + p.typed_input.key_header_bytes +
                p.typed_input.maximum_legacy_key_bytes + p.typed_input.maximum_key_text_bytes
        ]u8 = undefined;
        const encoded = try p.encodeKeyInput(payload[1..], input);
        payload[0] = @backingInt(p.InputKind.key);
        try stateOf(self).startInput(payload[0 .. 1 + encoded.len]);
    }

    /// Encodes one typed semantic mouse input before output mutation.
    pub fn sendMouse(self: *ByteClient, input: p.MouseInput) Error!void {
        var payload: [1 + p.typed_input.mouse_bytes]u8 = undefined;
        try p.encodeMouseInput(payload[1..], input);
        payload[0] = @backingInt(p.InputKind.mouse);
        try stateOf(self).startInput(&payload);
    }

    /// Encodes one closed typed focus value.
    pub fn sendFocus(self: *ByteClient, focus: p.InputFocus) Error!void {
        var payload: [1 + p.typed_input.focus_bytes]u8 = undefined;
        payload[0] = @backingInt(p.InputKind.focus);
        p.encodeFocusInput(payload[1..], focus);
        try stateOf(self).startInput(&payload);
    }

    /// Requests one coherent interaction-state response.
    pub fn interactionState(self: *ByteClient) Error!void {
        const s = stateOf(self);
        try s.requireIdle();
        try s.queue(.interaction_state, &.{});
        s.phase = .interaction;
    }

    /// Requests selected UTF-8 bytes into the caller's result storage.
    pub fn textExtract(self: *ByteClient, request: p.TextExtract) Error!void {
        const s = stateOf(self);
        try s.requireIdle();
        var payload: [p.payload_bytes.text_extract]u8 = undefined;
        p.encodeTextExtract(&payload, request);
        // The owned decoder validates the exact request grammar before queuing.
        const checked = try p.decodeTextExtract(&payload);
        if (checked.columns == 0) return error.InvalidPayload;
        try s.queue(.text_extract, &payload);
        s.phase = .selection;
    }

    /// Requests one exact image; a previous held image may be replaced explicitly.
    pub fn requestImage(self: *ByteClient, request: p.ImageRequest) Error!void {
        const s = stateOf(self);
        if (s.phase != .idle and s.phase != .image_ready) return error.InvalidState;
        if (request.image_id == 0 or request.generation == 0) return error.InvalidPayload;
        var payload: [p.payload_bytes.image_request]u8 = undefined;
        p.encodeImageRequest(&payload, request);
        try s.queue(.image_request, &payload);
        s.image_id = request.image_id;
        s.image_generation = request.generation;
        s.image_width = 0;
        s.image_height = 0;
        s.image_expected = 0;
        s.image_len = 0;
        s.image_started = false;
        s.phase = .image;
    }

    /// Releases a held result and permits ordinary requests again.
    pub fn releaseImage(self: *ByteClient) Error!void {
        const s = stateOf(self);
        if (s.phase != .image_ready) return error.InvalidState;
        s.image_id = 0;
        s.image_generation = 0;
        s.image_width = 0;
        s.image_height = 0;
        s.image_expected = 0;
        s.image_len = 0;
        s.image_started = false;
        s.phase = .idle;
    }

    /// Starts an explicit resize, optionally claiming this accepted client first.
    /// The choice to claim geometry belongs to the caller.
    pub fn resize(self: *ByteClient, request: p.Resize, claim: bool) Error!void {
        const s = stateOf(self);
        try s.requireIdle();
        var payload: [p.payload_bytes.resize]u8 = undefined;
        p.encodeResize(&payload, request);
        const checked = try p.decodeResize(&payload);
        if (checked.rows == 0 or checked.columns == 0) return error.InvalidPayload;
        if (claim) {
            var leader: [p.payload_bytes.assign_leader]u8 = undefined;
            p.encodeAssignLeader(&leader, .{ .client_id = s.ready.?.client_id });
            // Prove both request capacities before starting the two-part exchange.
            if (payload.len > s.buffers.outgoing.len - p.header_bytes) return error.BufferTooSmall;
            try s.queue(.assign_leader, &leader);
            s.operation = .claim_resize;
        } else {
            try s.queue(.resize, &payload);
            s.operation = .resize;
        }
        s.pending_resize = request;
        s.phase = .control;
    }

    /// Receives arbitrary splits, returning at the first complete response event.
    /// Invalid framed responses retire the stream; invalid buffer aliases do not
    /// consume bytes. A response borrow expires as documented by its storage lane.
    pub fn feed(self: *ByteClient, bytes: []const u8) Error!Feed {
        const s = stateOf(self);
        if (s.phase == .closed or s.phase == .retired) return error.InvalidState;
        try s.validateInput(bytes);
        errdefer self.retire();
        return s.feed(bytes);
    }

    /// Accepts clean EOF only between exchanges, with no partial frame.
    pub fn finish(self: *ByteClient) Error!void {
        const s = stateOf(self);
        if (s.phase == .retired) return error.InvalidState;
        errdefer self.retire();
        if (s.used != 0 or switch (s.phase) {
            .ready, .observation, .control, .image, .interaction, .selection => true,
            else => false,
        }) return error.TruncatedResponse;
        s.operation = .none;
        s.phase = .closed;
        s.output_len = 0;
    }
};

fn stateOf(client: *ByteClient) *State {
    // zig-audit: acknowledge ptr_cast
    // reason: ByteClient is created only from exactly aligned caller Storage holding one private State.
    // zig-audit: acknowledge align_cast
    // reason: init captures the State alignment of Storage and the handle preserves its address.
    return @ptrCast(@alignCast(client));
}

fn constStateOf(client: *const ByteClient) *const State {
    // zig-audit: acknowledge ptr_cast
    // reason: The const opaque handle borrows init's exact caller-owned State without exposing mutation.
    // zig-audit: acknowledge align_cast
    // reason: init captures State alignment and the const handle preserves the same address.
    return @ptrCast(@alignCast(client));
}

fn spansOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const left = @intFromPtr(a.ptr);
    const right = @intFromPtr(b.ptr);
    return if (left <= right) right - left < a.len else left - right < b.len;
}

fn validateBuffers(storage: *Storage, buffers: Buffers) Error!void {
    if (buffers.packet.len < p.header_bytes or buffers.outgoing.len < p.header_bytes)
        return error.InvalidBuffers;
    const spans = [_][]const u8{
        &storage.bytes, buffers.packet, buffers.outgoing, buffers.observation, buffers.result,
    };
    for (spans, 0..) |span, index| for (spans[0..index]) |previous| {
        if (spansOverlap(span, previous)) return error.InvalidBuffers;
    };
}

const Phase = enum { closed, ready, idle, observation, control, interaction, selection, image, image_ready, retired };
const Operation = enum { none, input, claim_resize, resize };
const Envelope = enum { begin, body, properties, end };
const State = struct {
    buffers: Buffers,
    phase: Phase = .closed,
    used: usize = 0,
    needed: usize = p.header_bytes,
    output_len: usize = 0,
    observation_len: usize = 0,
    ready: ?server.AttachReady = null,
    mode: ObservationMode = .collect,
    begin: ?p.SnapshotBegin = null,
    envelope: Envelope = .begin,
    body_kind: ?p.Kind = null,
    operation: Operation = .none,
    pending_resize: p.Resize = .{ .rows = 0, .columns = 0 },
    image_id: u32 = 0,
    image_generation: u64 = 0,
    image_width: u32 = 0,
    image_height: u32 = 0,
    image_expected: usize = 0,
    image_len: usize = 0,
    image_started: bool = false,

    fn validateInput(self: *const State, bytes: []const u8) Error!void {
        const spans = [_][]const u8{ std.mem.asBytes(self), self.buffers.packet, self.buffers.outgoing, self.buffers.observation, self.buffers.result };
        for (spans) |span| if (spansOverlap(bytes, span)) return error.InvalidInputAlias;
    }

    fn requireIdle(self: *const State) Error!void {
        if (self.phase != .idle) return error.InvalidState;
    }

    fn queue(self: *State, kind: p.Kind, payload: []const u8) Error!void {
        if (payload.len > self.buffers.outgoing.len - p.header_bytes) return error.BufferTooSmall;
        try p.encodeHeader(self.buffers.outgoing[0..p.header_bytes], .{ .kind = kind, .payload_len = @intCast(payload.len) });
        @memcpy(self.buffers.outgoing[p.header_bytes..][0..payload.len], payload);
        self.output_len = p.header_bytes + payload.len;
    }

    fn startInput(self: *State, payload: []const u8) Error!void {
        try self.requireIdle();
        try self.queue(.input, payload);
        self.operation = .input;
        self.phase = .control;
    }

    fn acceptEnvelope(self: *State, kind: p.Kind) Error!void {
        switch (self.envelope) {
            .begin => {
                if (kind != .snapshot_begin) return error.UnexpectedSnapshotFrame;
                self.envelope = .body;
            },
            .body => switch (kind) {
                .snapshot_data, .snapshot_raw_data => {
                    if (self.body_kind) |accepted| {
                        if (accepted != kind) return error.MixedSnapshotBodyEncoding;
                    } else self.body_kind = kind;
                },
                .snapshot_graphics => {
                    if (self.body_kind == null) return error.MissingSnapshotBody;
                    self.envelope = .properties;
                },
                else => return error.UnexpectedSnapshotFrame,
            },
            .properties => {
                if (kind != .snapshot_properties) return error.UnexpectedSnapshotFrame;
                self.envelope = .end;
            },
            .end => if (kind != .snapshot_end) return error.UnexpectedSnapshotFrame,
        }
    }

    fn acceptFrame(self: *State) Error!Event {
        const payload = self.buffers.packet[p.header_bytes..self.needed];
        if (self.phase == .ready) {
            const header = try server.decodeHeader(self.buffers.packet[0..p.header_bytes]);
            if (header.kind != .attach_ready) return error.ExpectedAttachReady;
            const ready = try server.decodeAttachReady(payload);
            self.ready = ready;
            self.phase = .idle;
            return .{ .attached = ready };
        }
        const header = try p.decodeHeader(self.buffers.packet[0..p.header_bytes]);
        switch (self.phase) {
            .observation => {
                if (self.mode == .live) {
                    try self.acceptEnvelope(header.kind);
                    if (header.kind == .snapshot_begin) self.begin = try p.decodeSnapshotBegin(payload);
                } else if ((self.observation_len == 0 and header.kind != .snapshot_begin) or
                    (self.observation_len != 0 and header.kind != .snapshot_data and
                        header.kind != .snapshot_raw_data and header.kind != .snapshot_graphics and
                        header.kind != .snapshot_properties and header.kind != .snapshot_end))
                {
                    return error.UnexpectedSnapshotFrame;
                }
                if (self.needed > self.buffers.observation.len - self.observation_len or
                    self.needed > p.maximum_observation_bytes - self.observation_len) return error.SnapshotTooLarge;
                @memcpy(self.buffers.observation[self.observation_len..][0..self.needed], self.buffers.packet[0..self.needed]);
                self.observation_len += self.needed;
                if (header.kind != .snapshot_end) return .progress;
                if (self.mode == .live) {
                    const begin = self.begin orelse return error.UnexpectedSnapshotFrame;
                    const end = try p.decodeSnapshotEnd(payload);
                    if (end.revision != begin.revision) return error.SnapshotRevisionMismatch;
                    if (begin.terminal.history_offset != 0) return error.LiveHistoryOffsetMismatch;
                }
                self.phase = .idle;
                return .{ .observation = self.begin };
            },
            .control => {
                if (header.kind != .result) return error.ExpectedControlResult;
                const result = try p.decodeResult(payload);
                switch (self.operation) {
                    .input => if (result.request_kind != .input) return error.InputRejected,
                    .claim_resize => {
                        if (result.request_kind != .assign_leader) return error.ResizeLeaderRejected;
                        if (result.code == .ok) {
                            var resize_payload: [p.payload_bytes.resize]u8 = undefined;
                            p.encodeResize(&resize_payload, self.pending_resize);
                            try self.queue(.resize, &resize_payload);
                            self.operation = .resize;
                            return .{ .outgoing_followup = result };
                        }
                    },
                    .resize => if (result.request_kind != .resize) return error.ResizeResultMismatch,
                    .none => return error.MissingControlOperation,
                }
                self.operation = .none;
                self.phase = .idle;
                return .{ .result = result };
            },
            .interaction => {
                if (header.kind == .result) {
                    const result = p.decodeResult(payload) catch return error.ExpectedInteractionStateSnapshot;
                    if (result.request_kind != .interaction_state or result.code == .ok)
                        return error.ExpectedInteractionStateSnapshot;
                    self.phase = .idle;
                    return .{ .result = result };
                }
                if (header.kind != .interaction_state_snapshot) return error.ExpectedInteractionStateSnapshot;
                const interaction = try p.decodeInteractionStateSnapshot(payload);
                self.phase = .idle;
                return .{ .interaction = interaction };
            },
            .selection => {
                if (header.kind == .result) {
                    const result = try p.decodeResult(payload);
                    if (result.request_kind != .text_extract or result.code == .ok) return error.TextExtractResultMismatch;
                    self.phase = .idle;
                    return .{ .result = result };
                }
                if (header.kind != .text_extract_data or
                    !std.unicode.utf8ValidateSlice(payload)) return error.InvalidTextExtractData;
                if (payload.len > self.buffers.result.len) return error.ResultTooSmall;
                @memcpy(self.buffers.result[0..payload.len], payload);
                self.phase = .idle;
                return .{ .text = self.buffers.result[0..payload.len] };
            },
            .image => {
                if (!self.image_started) {
                    if (header.kind == .result) {
                        const result = try p.decodeResult(payload);
                        if (result.request_kind != .image_request or result.code == .ok) return error.ImageResultMismatch;
                        self.phase = .idle;
                        return .{ .result = result };
                    }
                    if (header.kind != .image_begin) return error.ExpectedImageBegin;
                    const begin = try p.decodeImageBegin(payload);
                    if (begin.image_id != self.image_id or begin.generation != self.image_generation)
                        return error.ImageIdentityMismatch;
                    if (begin.byte_count > self.buffers.result.len) return error.ResultTooSmall;
                    self.image_width = begin.width;
                    self.image_height = begin.height;
                    self.image_expected = begin.byte_count;
                    self.image_len = 0;
                    self.image_started = true;
                    return .progress;
                }
                if (header.kind == .image_data) {
                    if (payload.len == 0 or payload.len > p.image_data_chunk_bytes or
                        payload.len > self.image_expected - self.image_len) return error.InvalidImageData;
                    @memcpy(self.buffers.result[self.image_len..][0..payload.len], payload);
                    self.image_len += payload.len;
                    return .progress;
                }
                if (header.kind != .image_end or self.image_len != self.image_expected) return error.ExpectedImageEnd;
                const end = try p.decodeImageEnd(payload);
                if (end.image_id != self.image_id or end.generation != self.image_generation) return error.ImageIdentityMismatch;
                self.phase = .image_ready;
                return .{ .image = .{ .image_id = self.image_id, .generation = self.image_generation, .width = self.image_width, .height = self.image_height, .bytes = self.buffers.result[0..self.image_len] } };
            },
            else => return error.UnsolicitedFrame,
        }
    }

    fn feed(self: *State, bytes: []const u8) Error!Feed {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const count = @min(bytes.len - offset, self.needed - self.used);
            @memcpy(self.buffers.packet[self.used..][0..count], bytes[offset..][0..count]);
            offset += count;
            self.used += count;
            if (self.used != self.needed) continue;
            if (self.needed == p.header_bytes) {
                const payload_len = if (self.phase == .ready)
                    (try server.decodeHeader(self.buffers.packet[0..p.header_bytes])).payload_len
                else
                    (try p.decodeHeader(self.buffers.packet[0..p.header_bytes])).payload_len;
                if (payload_len > self.buffers.packet.len - p.header_bytes) return error.BufferTooSmall;
                self.needed = p.header_bytes + payload_len;
                if (self.used != self.needed) continue;
            }
            const event = try self.acceptFrame();
            self.used = 0;
            self.needed = p.header_bytes;
            if (event != .progress) return .{ .consumed = offset, .event = event };
        }
        return .{ .consumed = offset, .event = .progress };
    }
};
