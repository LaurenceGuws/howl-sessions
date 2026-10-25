//! Bounded Server control and dedicated Instance-attachment wire.
//! Successful attachment establishes terminal interaction on that same connection.
//! Session creation contains no process or terminal geometry policy.

const std = @import("std");
const framing = @import("framing.zig");

/// Terminal interaction wire owned by this Server implementation.
pub const terminal = @import("terminal.zig");

/// Version of the bounded Server control frame envelope.
pub const framing_version: u8 = framing.version;
/// Exact encoded control frame header length.
pub const header_bytes: usize = framing.header_bytes;
/// Upper bound on any control request payload.
pub const maximum_request_payload_bytes: usize = 8 * 1024;
/// Upper bound on any control frame payload.
pub const maximum_payload_bytes: usize = 8 * 1024;
/// Wire catalogue bound on simultaneous Sessions.
pub const maximum_sessions: u16 = 16;
/// Wire catalogue bound on Instances in one Session.
pub const maximum_instances_per_session: u16 = 16;
/// Maximum encoded Session name byte length.
pub const maximum_session_name_bytes: usize = 64;
/// Maximum encoded shell path byte length.
pub const maximum_shell_bytes: usize = 1024;
/// Maximum encoded command byte length.
pub const maximum_command_bytes: usize = 4096;
/// Maximum encoded working-directory byte length.
pub const maximum_cwd_bytes: usize = 1024;

/// Frozen control request and response frame tags.
pub const Kind = enum(u8) {
    hello = 1,
    welcome = 2,
    status = 3,
    status_snapshot = 4,
    observe_tree = 5,
    tree_snapshot = 6,
    create_session = 7,
    close_session = 8,
    create_instance = 9,
    close_instance = 10,
    attach_instance = 11,
    attach_ready = 12,
    result = 13,
};

/// Control frame tag and bounded payload length.
pub const Header = framing.Header(Kind);

/// Reports invalid framing before any control payload is admitted.
pub const HeaderError = framing.Error;

/// Reports malformed or out-of-domain control payloads.
pub const PayloadError = error{InvalidPayload};
/// Reports invalid payload values or insufficient output capacity.
pub const EncodeError = PayloadError || error{OutputTooSmall};

/// Frozen retained Instance lifecycle tags.
pub const InstanceState = enum(u8) {
    running = 1,
    exited = 2,
};

/// Frozen typed results for control operations.
pub const ResultCode = enum(u8) {
    ok = 1,
    malformed = 2,
    unsupported = 3,
    session_not_found = 4,
    instance_not_found = 5,
    name_exists = 6,
    session_capacity = 7,
    instance_capacity = 8,
    create_failed = 9,
    unavailable = 10,
    internal = 11,
};

/// Server incarnation, catalogue revision and bounded counts.
pub const Status = struct {
    server_id: u64,
    tree_revision: u64,
    session_count: u16,
    instance_count: u16,
    session_capacity: u16 = maximum_sessions,
    instances_per_session: u16 = maximum_instances_per_session,
};

/// Catalogue revision after which the client wants an observation.
pub const ObserveTree = struct {
    after_revision: u64,
};

/// Session name borrowed for the duration of encoding.
pub const CreateSession = struct {
    name: []const u8,
};

/// Exact nonzero Session/Instance occurrence selection.
pub const InstanceIdentity = struct {
    session_id: u64,
    instance_id: u64,
};

/// Explicit process and geometry request with borrowed launch bytes.
pub const CreateInstance = struct {
    session_id: u64,
    shell: []const u8,
    command: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    rows: u16,
    columns: u16,
    history_rows: u16,
};

/// Typed control result and resulting catalogue revision.
pub const Result = struct {
    request_kind: Kind,
    code: ResultCode,
    session_id: u64 = 0,
    instance_id: u64 = 0,
    tree_revision: u64 = 0,
};

/// Exact occurrence and catalogue revision at stream handoff.
pub const AttachReady = struct {
    server_id: u64,
    session_id: u64,
    instance_id: u64,
    tree_revision: u64,
    client_id: terminal.ClientId,
};

/// Session facts with borrowed name and Instance records.
pub const SessionRecord = struct {
    session_id: u64,
    name: []const u8,
    instances: []const InstanceRecord,
};

/// Copied Instance identity and lifecycle tag.
pub const InstanceRecord = struct {
    instance_id: u64,
    state: InstanceState,
};

/// Catalogue header uses the Status wire representation.
pub const TreeHeader = Status;

/// Exact fixed payload sizes and variable-record prefix sizes.
pub const payload_bytes = struct {
    /// Encoded hello payload or prefix size in bytes.
    pub const hello: usize = 0;
    /// Encoded welcome payload or prefix size in bytes.
    pub const welcome: usize = 32;
    /// Encoded status payload or prefix size in bytes.
    pub const status: usize = 0;
    /// Encoded status snapshot payload or prefix size in bytes.
    pub const status_snapshot: usize = 32;
    /// Encoded observe tree payload or prefix size in bytes.
    pub const observe_tree: usize = 8;
    /// Encoded create session header payload or prefix size in bytes.
    pub const create_session_header: usize = 8;
    /// Encoded session identity payload or prefix size in bytes.
    pub const session_identity: usize = 8;
    /// Encoded create instance header payload or prefix size in bytes.
    pub const create_instance_header: usize = 24;
    /// Encoded instance identity payload or prefix size in bytes.
    pub const instance_identity: usize = 16;
    /// Encoded attach ready payload or prefix size in bytes.
    pub const attach_ready: usize = 40;
    /// Encoded result payload or prefix size in bytes.
    pub const result: usize = 32;
    /// Encoded tree header payload or prefix size in bytes.
    pub const tree_header: usize = 32;
    /// Encoded session record header payload or prefix size in bytes.
    pub const session_record_header: usize = 16;
    /// Encoded Instance record size in bytes.
    pub const instance_record: usize = 16;
};

/// Validates and encodes header into caller-owned output.
pub fn encodeHeader(output: *[header_bytes]u8, value: Header) error{PayloadTooLarge}!void {
    return framing.encode(Kind, maximum_payload_bytes, output, value);
}

/// Rejects terminal tags and oversized control payloads before allocation.
pub fn decodeHeader(input: *const [header_bytes]u8) HeaderError!Header {
    return framing.decode(Kind, maximum_payload_bytes, input);
}

/// Validates and encodes status into caller-owned output.
pub fn encodeStatus(output: *[payload_bytes.status_snapshot]u8, value: Status) PayloadError!void {
    try validateStatus(value);
    output.* = @splat(0);
    writeU64(output[0..8], value.server_id);
    writeU64(output[8..16], value.tree_revision);
    writeU16(output[16..18], value.session_count);
    writeU16(output[18..20], value.instance_count);
    writeU16(output[20..22], value.session_capacity);
    writeU16(output[22..24], value.instances_per_session);
}

/// Decodes and validates status from the exact wire payload.
pub fn decodeStatus(input: []const u8) PayloadError!Status {
    if (input.len != payload_bytes.status_snapshot or !allZero(input[24..32]))
        return error.InvalidPayload;
    const value = Status{
        .server_id = readU64(input[0..8]),
        .tree_revision = readU64(input[8..16]),
        .session_count = readU16(input[16..18]),
        .instance_count = readU16(input[18..20]),
        .session_capacity = readU16(input[20..22]),
        .instances_per_session = readU16(input[22..24]),
    };
    try validateStatus(value);
    return value;
}

/// Validates and encodes observe tree into caller-owned output.
pub fn encodeObserveTree(output: *[payload_bytes.observe_tree]u8, value: ObserveTree) void {
    writeU64(output, value.after_revision);
}

/// Decodes and validates observe tree from the exact wire payload.
pub fn decodeObserveTree(input: []const u8) PayloadError!ObserveTree {
    if (input.len != payload_bytes.observe_tree) return error.InvalidPayload;
    return .{ .after_revision = readU64(input) };
}

/// Validates a Session request and returns its exact encoded size.
pub fn createSessionEncodedBytes(value: CreateSession) PayloadError!usize {
    try validateSessionName(value.name);
    return payload_bytes.create_session_header + value.name.len;
}

/// Validates and encodes create session into caller-owned output.
pub fn encodeCreateSession(output: []u8, value: CreateSession) EncodeError![]const u8 {
    const needed = try createSessionEncodedBytes(value);
    if (output.len < needed) return error.OutputTooSmall;
    const encoded = output[0..needed];
    @memset(encoded[0..payload_bytes.create_session_header], 0);
    encoded[0] = @intCast(value.name.len);
    @memcpy(encoded[payload_bytes.create_session_header..], value.name);
    return encoded;
}

/// Decodes and validates create session from the exact wire payload.
pub fn decodeCreateSession(input: []const u8) PayloadError!CreateSession {
    if (input.len < payload_bytes.create_session_header or !allZero(input[1..payload_bytes.create_session_header]))
        return error.InvalidPayload;
    const name_len: usize = input[0];
    if (input.len != payload_bytes.create_session_header + name_len) return error.InvalidPayload;
    const value = CreateSession{ .name = input[payload_bytes.create_session_header..] };
    try validateSessionName(value.name);
    return value;
}

/// Validates and encodes session identity into caller-owned output.
pub fn encodeSessionIdentity(output: *[payload_bytes.session_identity]u8, session_id: u64) PayloadError!void {
    if (session_id == 0) return error.InvalidPayload;
    writeU64(output, session_id);
}

/// Decodes and validates session identity from the exact wire payload.
pub fn decodeSessionIdentity(input: []const u8) PayloadError!u64 {
    if (input.len != payload_bytes.session_identity) return error.InvalidPayload;
    const value = readU64(input);
    if (value == 0) return error.InvalidPayload;
    return value;
}

/// Validates an Instance request and returns its exact encoded size.
pub fn createInstanceEncodedBytes(value: CreateInstance) PayloadError!usize {
    try validateCreateInstance(value);
    return payload_bytes.create_instance_header + value.shell.len +
        (if (value.command) |text| text.len else 0) +
        (if (value.cwd) |text| text.len else 0);
}

/// Validates and encodes create instance into caller-owned output.
pub fn encodeCreateInstance(output: []u8, value: CreateInstance) EncodeError![]const u8 {
    const needed = try createInstanceEncodedBytes(value);
    if (output.len < needed) return error.OutputTooSmall;
    const encoded = output[0..needed];
    @memset(encoded[0..payload_bytes.create_instance_header], 0);
    writeU64(encoded[0..8], value.session_id);
    writeU16(encoded[8..10], value.rows);
    writeU16(encoded[10..12], value.columns);
    writeU16(encoded[12..14], value.history_rows);
    writeU16(encoded[14..16], @intCast(value.shell.len));
    writeU16(encoded[16..18], @intCast(if (value.command) |text| text.len else 0));
    writeU16(encoded[18..20], @intCast(if (value.cwd) |text| text.len else 0));
    var offset: usize = payload_bytes.create_instance_header;
    @memcpy(encoded[offset .. offset + value.shell.len], value.shell);
    offset += value.shell.len;
    if (value.command) |text| {
        @memcpy(encoded[offset .. offset + text.len], text);
        offset += text.len;
    }
    if (value.cwd) |text| @memcpy(encoded[offset .. offset + text.len], text);
    return encoded;
}

/// Decodes and validates create instance from the exact wire payload.
pub fn decodeCreateInstance(input: []const u8) PayloadError!CreateInstance {
    if (input.len < payload_bytes.create_instance_header or !allZero(input[20..24]))
        return error.InvalidPayload;
    const shell_len: usize = readU16(input[14..16]);
    const command_len: usize = readU16(input[16..18]);
    const cwd_len: usize = readU16(input[18..20]);
    const total = payload_bytes.create_instance_header + shell_len + command_len + cwd_len;
    if (total != input.len) return error.InvalidPayload;
    var offset: usize = payload_bytes.create_instance_header;
    const shell = input[offset .. offset + shell_len];
    offset += shell_len;
    const command = input[offset .. offset + command_len];
    offset += command_len;
    const cwd = input[offset .. offset + cwd_len];
    const value = CreateInstance{
        .session_id = readU64(input[0..8]),
        .rows = readU16(input[8..10]),
        .columns = readU16(input[10..12]),
        .history_rows = readU16(input[12..14]),
        .shell = shell,
        .command = if (command.len == 0) null else command,
        .cwd = if (cwd.len == 0) null else cwd,
    };
    try validateCreateInstance(value);
    return value;
}

/// Validates and encodes instance identity into caller-owned output.
pub fn encodeInstanceIdentity(output: *[payload_bytes.instance_identity]u8, value: InstanceIdentity) PayloadError!void {
    try validateInstanceIdentity(value);
    writeU64(output[0..8], value.session_id);
    writeU64(output[8..16], value.instance_id);
}

/// Decodes and validates instance identity from the exact wire payload.
pub fn decodeInstanceIdentity(input: []const u8) PayloadError!InstanceIdentity {
    if (input.len != payload_bytes.instance_identity) return error.InvalidPayload;
    const value = InstanceIdentity{
        .session_id = readU64(input[0..8]),
        .instance_id = readU64(input[8..16]),
    };
    try validateInstanceIdentity(value);
    return value;
}

/// Validates and encodes attach ready into caller-owned output.
pub fn encodeAttachReady(output: *[payload_bytes.attach_ready]u8, value: AttachReady) PayloadError!void {
    try validateAttachReady(value);
    writeU64(output[0..8], value.server_id);
    writeU64(output[8..16], value.session_id);
    writeU64(output[16..24], value.instance_id);
    writeU64(output[24..32], value.tree_revision);
    writeU64(output[32..40], value.client_id);
}

/// Decodes one complete accepted attachment, including terminal client identity.
pub fn decodeAttachReady(input: []const u8) PayloadError!AttachReady {
    if (input.len != payload_bytes.attach_ready) return error.InvalidPayload;
    const value = AttachReady{
        .server_id = readU64(input[0..8]),
        .session_id = readU64(input[8..16]),
        .instance_id = readU64(input[16..24]),
        .tree_revision = readU64(input[24..32]),
        .client_id = readU64(input[32..40]),
    };
    try validateAttachReady(value);
    return value;
}

fn validateAttachReady(value: AttachReady) PayloadError!void {
    try validateInstanceIdentity(.{ .session_id = value.session_id, .instance_id = value.instance_id });
    if (value.server_id == 0 or value.tree_revision == 0 or value.client_id == terminal.no_client)
        return error.InvalidPayload;
}

/// Validates and encodes result into caller-owned output.
pub fn encodeResult(output: *[payload_bytes.result]u8, value: Result) PayloadError!void {
    if (!resultRequestKind(value.request_kind) or value.tree_revision == 0) return error.InvalidPayload;
    if (value.code == .ok) switch (value.request_kind) {
        .create_session => if (value.session_id == 0 or value.instance_id != 0) return error.InvalidPayload,
        .create_instance => if (value.session_id == 0 or value.instance_id == 0) return error.InvalidPayload,
        .close_session => if (value.session_id == 0 or value.instance_id != 0) return error.InvalidPayload,
        .close_instance => if (value.session_id == 0 or value.instance_id == 0) return error.InvalidPayload,
        .attach_instance => return error.InvalidPayload,
        else => return error.InvalidPayload,
    };
    output.* = @splat(0);
    output[0] = @backingInt(value.request_kind);
    output[1] = @backingInt(value.code);
    writeU64(output[8..16], value.session_id);
    writeU64(output[16..24], value.instance_id);
    writeU64(output[24..32], value.tree_revision);
}

/// Decodes and validates result from the exact wire payload.
pub fn decodeResult(input: []const u8) PayloadError!Result {
    if (input.len != payload_bytes.result or !allZero(input[2..8])) return error.InvalidPayload;
    const request_kind = enumFromInt(Kind, input[0]) orelse return error.InvalidPayload;
    if (!resultRequestKind(request_kind)) return error.InvalidPayload;
    const code = enumFromInt(ResultCode, input[1]) orelse return error.InvalidPayload;
    const value = Result{
        .request_kind = request_kind,
        .code = code,
        .session_id = readU64(input[8..16]),
        .instance_id = readU64(input[16..24]),
        .tree_revision = readU64(input[24..32]),
    };
    var encoded: [payload_bytes.result]u8 = undefined;
    try encodeResult(&encoded, value);
    return value;
}

/// Validates catalogue facts and returns their exact encoded byte count.
pub fn treeEncodedBytes(status: Status, sessions: []const SessionRecord) PayloadError!usize {
    try validateTree(status, sessions);
    var total: usize = payload_bytes.tree_header;
    for (sessions) |session| {
        total += payload_bytes.session_record_header + session.name.len;
        total += session.instances.len * payload_bytes.instance_record;
    }
    if (total > maximum_payload_bytes) return error.InvalidPayload;
    return total;
}

/// Validates and writes one bounded catalogue snapshot into caller-owned output.
pub fn encodeTreeSnapshot(output: []u8, status: Status, sessions: []const SessionRecord) EncodeError![]const u8 {
    const needed = try treeEncodedBytes(status, sessions);
    if (output.len < needed) return error.OutputTooSmall;
    var header: [payload_bytes.tree_header]u8 = undefined;
    try encodeStatus(&header, status);
    @memcpy(output[0..header.len], &header);
    var offset: usize = header.len;
    for (sessions) |session| {
        const header_slice = output[offset..][0..payload_bytes.session_record_header];
        @memset(header_slice, 0);
        writeU64(header_slice[0..8], session.session_id);
        writeU16(header_slice[8..10], @intCast(session.instances.len));
        header_slice[10] = @intCast(session.name.len);
        offset += header_slice.len;
        @memcpy(output[offset .. offset + session.name.len], session.name);
        offset += session.name.len;
        for (session.instances) |instance| {
            const encoded = output[offset..][0..payload_bytes.instance_record];
            @memset(encoded, 0);
            writeU64(encoded[0..8], instance.instance_id);
            encoded[8] = @backingInt(instance.state);
            offset += encoded.len;
        }
    }
    std.debug.assert(offset == needed);
    return output[0..needed];
}

/// Stateful bounded decoder borrowing one validated tree payload.
pub const TreeDecoder = struct {
    input: []const u8,
    header: TreeHeader,
    offset: usize = payload_bytes.tree_header,
    sessions_seen: u16 = 0,
    instances_seen: u16 = 0,
    pending_instances: u16 = 0,
    previous_session_id: u64 = 0,
    previous_instance_id: u64 = 0,

    /// Session facts borrowed from the decoder's input.
    pub const DecodedSession = struct {
        session_id: u64,
        name: []const u8,
        instance_count: u16,
    };

    /// Validates the tree header and starts decoding borrowed catalogue records.
    pub fn init(input: []const u8) PayloadError!TreeDecoder {
        if (input.len < payload_bytes.tree_header) return error.InvalidPayload;
        const header = try decodeStatus(input[0..payload_bytes.tree_header]);
        return .{ .input = input, .header = header };
    }

    /// Decodes the next ordered Session record after its Instances are consumed.
    pub fn nextSession(self: *TreeDecoder) PayloadError!?DecodedSession {
        if (self.pending_instances != 0) return error.InvalidPayload;
        if (self.sessions_seen == self.header.session_count) {
            if (self.instances_seen != self.header.instance_count or self.offset != self.input.len)
                return error.InvalidPayload;
            return null;
        }
        if (self.offset + payload_bytes.session_record_header > self.input.len) return error.InvalidPayload;
        const encoded = self.input[self.offset..][0..payload_bytes.session_record_header];
        if (!allZero(encoded[11..16])) return error.InvalidPayload;
        const session_id = readU64(encoded[0..8]);
        const instance_count = readU16(encoded[8..10]);
        const name_len: usize = encoded[10];
        if (session_id <= self.previous_session_id or instance_count > maximum_instances_per_session or
            name_len == 0 or name_len > maximum_session_name_bytes)
            return error.InvalidPayload;
        self.offset += encoded.len;
        if (self.offset + name_len > self.input.len) return error.InvalidPayload;
        const name = self.input[self.offset .. self.offset + name_len];
        try validateSessionName(name);
        self.offset += name_len;
        self.sessions_seen += 1;
        self.pending_instances = instance_count;
        self.previous_session_id = session_id;
        self.previous_instance_id = 0;
        return .{ .session_id = session_id, .name = name, .instance_count = instance_count };
    }

    /// Decodes the next Instance belonging to the current Session.
    pub fn nextInstance(self: *TreeDecoder) PayloadError!InstanceRecord {
        if (self.pending_instances == 0) return error.InvalidPayload;
        if (self.offset + payload_bytes.instance_record > self.input.len) return error.InvalidPayload;
        const encoded = self.input[self.offset..][0..payload_bytes.instance_record];
        if (!allZero(encoded[9..16])) return error.InvalidPayload;
        const instance_id = readU64(encoded[0..8]);
        const state = enumFromInt(InstanceState, encoded[8]) orelse return error.InvalidPayload;
        if (instance_id <= self.previous_instance_id) return error.InvalidPayload;
        self.previous_instance_id = instance_id;
        self.offset += encoded.len;
        self.instances_seen += 1;
        self.pending_instances -= 1;
        if (self.instances_seen > self.header.instance_count) return error.InvalidPayload;
        return .{ .instance_id = instance_id, .state = state };
    }
};

fn validateStatus(value: Status) PayloadError!void {
    if (value.server_id == 0 or value.tree_revision == 0 or
        value.session_capacity != maximum_sessions or
        value.instances_per_session != maximum_instances_per_session or
        value.session_count > value.session_capacity or
        value.instance_count > value.session_capacity * value.instances_per_session)
        return error.InvalidPayload;
}

/// Model and wire share this exact bounded ASCII name contract.
pub fn validateSessionName(name: []const u8) PayloadError!void {
    if (name.len == 0 or name.len > maximum_session_name_bytes) return error.InvalidPayload;
    for (name) |byte| if (!((byte >= 'a' and byte <= 'z') or
        (byte >= 'A' and byte <= 'Z') or
        (byte >= '0' and byte <= '9') or byte == '.' or byte == '_' or byte == '-'))
        return error.InvalidPayload;
}

fn validateCreateInstance(value: CreateInstance) PayloadError!void {
    if (value.session_id == 0 or value.rows == 0 or value.columns == 0 or value.history_rows == 0 or
        value.shell.len == 0 or value.shell.len > maximum_shell_bytes or
        std.mem.indexOfScalar(u8, value.shell, 0) != null or
        (value.command != null and (value.command.?.len == 0 or
            value.command.?.len > maximum_command_bytes or
            std.mem.indexOfScalar(u8, value.command.?, 0) != null)) or
        (value.cwd != null and (value.cwd.?.len == 0 or
            value.cwd.?.len > maximum_cwd_bytes or
            std.mem.indexOfScalar(u8, value.cwd.?, 0) != null)))
        return error.InvalidPayload;
}

fn validateInstanceIdentity(value: InstanceIdentity) PayloadError!void {
    if (value.session_id == 0 or value.instance_id == 0) return error.InvalidPayload;
}

fn validateTree(status: Status, sessions: []const SessionRecord) PayloadError!void {
    try validateStatus(status);
    if (sessions.len != status.session_count or sessions.len > maximum_sessions) return error.InvalidPayload;
    var instances: usize = 0;
    var previous_session_id: u64 = 0;
    for (sessions) |session| {
        if (session.session_id == 0 or session.session_id <= previous_session_id) return error.InvalidPayload;
        previous_session_id = session.session_id;
        try validateSessionName(session.name);
        if (session.instances.len > maximum_instances_per_session) return error.InvalidPayload;
        var previous_instance_id: u64 = 0;
        for (session.instances) |instance| {
            if (instance.instance_id == 0 or instance.instance_id <= previous_instance_id) return error.InvalidPayload;
            previous_instance_id = instance.instance_id;
            instances += 1;
        }
    }
    if (instances != status.instance_count) return error.InvalidPayload;
}

fn resultRequestKind(kind: Kind) bool {
    return switch (kind) {
        .create_session, .close_session, .create_instance, .close_instance, .attach_instance => true,
        else => false,
    };
}

fn enumFromInt(comptime E: type, value: @typeInfo(E).@"enum".tag_type) ?E {
    const info = @typeInfo(E).@"enum";
    inline for (info.field_values) |field_value| {
        if (value == field_value) return @fromBackingInt(@intCast(value));
    }
    return null;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn writeU16(output: []u8, value: u16) void {
    std.debug.assert(output.len == 2);
    output[0] = @truncate(value >> 8);
    output[1] = @truncate(value);
}

fn writeU32(output: []u8, value: u32) void {
    std.debug.assert(output.len == 4);
    output[0] = @truncate(value >> 24);
    output[1] = @truncate(value >> 16);
    output[2] = @truncate(value >> 8);
    output[3] = @truncate(value);
}

fn writeU64(output: []u8, value: u64) void {
    std.debug.assert(output.len == 8);
    var shift: u6 = 56;
    for (output) |*byte| {
        byte.* = @truncate(value >> shift);
        shift -|= 8;
    }
}

fn readU16(input: []const u8) u16 {
    std.debug.assert(input.len == 2);
    return (@as(u16, input[0]) << 8) | input[1];
}

fn readU32(input: []const u8) u32 {
    std.debug.assert(input.len == 4);
    return (@as(u32, input[0]) << 24) |
        (@as(u32, input[1]) << 16) |
        (@as(u32, input[2]) << 8) |
        input[3];
}

fn readU64(input: []const u8) u64 {
    std.debug.assert(input.len == 8);
    var value: u64 = 0;
    for (input) |byte| value = (value << 8) | byte;
    return value;
}

test "Session create wire cannot carry Instance launch policy" {
    var storage: [128]u8 = undefined;
    const encoded = try encodeCreateSession(&storage, .{ .name = "work" });
    try std.testing.expectEqual(@as(usize, payload_bytes.create_session_header + 4), encoded.len);
    const decoded = try decodeCreateSession(encoded);
    try std.testing.expectEqualStrings("work", decoded.name);
    try std.testing.expectError(error.InvalidPayload, decodeCreateSession(&.{ 0, 0, 0, 0, 0, 0, 0, 0 }));
}

test "Instance create wire carries launch policy under exact Session identity" {
    var storage: [maximum_request_payload_bytes]u8 = undefined;
    const encoded = try encodeCreateInstance(&storage, .{
        .session_id = 7,
        .shell = "/bin/sh",
        .command = "printf hi",
        .cwd = "/tmp",
        .rows = 24,
        .columns = 80,
        .history_rows = 4096,
    });
    const decoded = try decodeCreateInstance(encoded);
    try std.testing.expectEqual(@as(u64, 7), decoded.session_id);
    try std.testing.expectEqualStrings("/bin/sh", decoded.shell);
    try std.testing.expectEqualStrings("printf hi", decoded.command.?);
    try std.testing.expectEqualStrings("/tmp", decoded.cwd.?);
    try std.testing.expectEqual(@as(u16, 24), decoded.rows);
    try std.testing.expectEqual(@as(u16, 80), decoded.columns);
    try std.testing.expectEqual(@as(u16, 4096), decoded.history_rows);
}

test "Instance create wire rejects noncanonical optional process text" {
    var storage: [maximum_request_payload_bytes]u8 = undefined;
    try std.testing.expectError(error.InvalidPayload, encodeCreateInstance(&storage, .{
        .session_id = 1,
        .shell = "/bin/sh",
        .command = "",
        .rows = 2,
        .columns = 8,
        .history_rows = 16,
    }));
    try std.testing.expectError(error.InvalidPayload, encodeCreateInstance(&storage, .{
        .session_id = 1,
        .shell = "/bin/sh",
        .cwd = "",
        .rows = 2,
        .columns = 8,
        .history_rows = 16,
    }));
}

test "attach failure result is legal while attach success stays attach_ready" {
    var encoded: [payload_bytes.result]u8 = undefined;
    try encodeResult(&encoded, .{
        .request_kind = .attach_instance,
        .code = .instance_not_found,
        .session_id = 7,
        .instance_id = 99,
        .tree_revision = 4,
    });
    const decoded = try decodeResult(&encoded);
    try std.testing.expectEqual(Kind.attach_instance, decoded.request_kind);
    try std.testing.expectEqual(ResultCode.instance_not_found, decoded.code);
    try std.testing.expectError(error.InvalidPayload, encodeResult(&encoded, .{
        .request_kind = .attach_instance,
        .code = .ok,
        .session_id = 7,
        .instance_id = 1,
        .tree_revision = 4,
    }));
}

test "tree snapshot preserves Server Session Instance hierarchy" {
    const work_instances = [_]InstanceRecord{
        .{ .instance_id = 1, .state = .running },
        .{ .instance_id = 2, .state = .exited },
    };
    const logs_instances = [_]InstanceRecord{
        .{ .instance_id = 1, .state = .running },
    };
    const sessions = [_]SessionRecord{
        .{ .session_id = 4, .name = "work", .instances = &work_instances },
        .{ .session_id = 9, .name = "logs", .instances = &logs_instances },
    };
    const status = Status{
        .server_id = 99,
        .tree_revision = 12,
        .session_count = 2,
        .instance_count = 3,
    };
    var storage: [maximum_payload_bytes]u8 = undefined;
    const encoded = try encodeTreeSnapshot(&storage, status, &sessions);
    var decoder = try TreeDecoder.init(encoded);
    const work = (try decoder.nextSession()).?;
    try std.testing.expectEqual(@as(u64, 4), work.session_id);
    try std.testing.expectEqualStrings("work", work.name);
    try std.testing.expectEqual(@as(u16, 2), work.instance_count);
    var sequence_probe = decoder;
    try std.testing.expectError(error.InvalidPayload, sequence_probe.nextSession());
    try std.testing.expectEqual(InstanceState.running, (try decoder.nextInstance()).state);
    try std.testing.expectEqual(InstanceState.exited, (try decoder.nextInstance()).state);
    const logs = (try decoder.nextSession()).?;
    try std.testing.expectEqual(@as(u64, 9), logs.session_id);
    try std.testing.expectEqual(@as(u16, 1), logs.instance_count);
    try std.testing.expectEqual(InstanceState.running, (try decoder.nextInstance()).state);
    try std.testing.expect((try decoder.nextSession()) == null);
}

test "tree and identity codecs reject ambiguity" {
    var identity: [payload_bytes.instance_identity]u8 = undefined;
    try encodeInstanceIdentity(&identity, .{ .session_id = 3, .instance_id = 5 });
    try std.testing.expectEqualDeep(
        InstanceIdentity{ .session_id = 3, .instance_id = 5 },
        try decodeInstanceIdentity(&identity),
    );
    identity[0..8].* = @splat(0);
    try std.testing.expectError(error.InvalidPayload, decodeInstanceIdentity(&identity));

    var header: [header_bytes]u8 = undefined;
    try encodeHeader(&header, .{ .kind = .create_session, .payload_len = 9 });
    try std.testing.expectEqual(Kind.create_session, (try decodeHeader(&header)).kind);
    header[6] = 1;
    try std.testing.expectError(error.InvalidReservedBits, decodeHeader(&header));
}

test "tree decoder requires encoder strict identity ordering without allocation" {
    const instances = [_]InstanceRecord{ .{ .instance_id = 2, .state = .running }, .{ .instance_id = 3, .state = .exited } };
    const sessions = [_]SessionRecord{ .{ .session_id = 2, .name = "a", .instances = &instances }, .{ .session_id = 3, .name = "b", .instances = &instances } };
    for ([_]bool{ false, true }) |mutate_session| {
        for ([_]u64{ 1, 2, 3 }) |id| {
            var bytes: [256]u8 = undefined;
            const encoded = try encodeTreeSnapshot(&bytes, .{ .server_id = 91, .tree_revision = 1, .session_count = 2, .instance_count = 4 }, &sessions);
            const offset: usize = if (mutate_session) 32 + 17 + 32 else 32 + 17 + 16;
            std.mem.writeInt(u64, bytes[offset..][0..8], id, .big);
            var decoder = try TreeDecoder.init(encoded);
            try std.testing.expect((try decoder.nextSession()) != null);
            try std.testing.expectEqual(@as(u64, 2), (try decoder.nextInstance()).instance_id);
            if (!mutate_session and id < 3) {
                try std.testing.expectError(error.InvalidPayload, decoder.nextInstance());
                continue;
            }
            try std.testing.expectEqual(@as(u64, 3), (try decoder.nextInstance()).instance_id);
            if (mutate_session and id < 3) {
                try std.testing.expectError(error.InvalidPayload, decoder.nextSession());
                continue;
            }
            try std.testing.expect((try decoder.nextSession()) != null);
            // Instance order resets for each Session.
            try std.testing.expectEqual(@as(u64, 2), (try decoder.nextInstance()).instance_id);
            try std.testing.expectEqual(@as(u64, 3), (try decoder.nextInstance()).instance_id);
            try std.testing.expectEqual(@as(?TreeDecoder.DecodedSession, null), try decoder.nextSession());
        }
    }
}

comptime {
    for (@typeInfo(Kind).@"enum".field_values) |control| {
        for (@typeInfo(terminal.Kind).@"enum".field_values) |interaction| {
            if (control == interaction)
                @compileError("Server control and terminal tags must be disjoint");
        }
    }
}

test "one Server envelope rejects cross-phase tags and complete attachment identity is exact" {
    var header: [header_bytes]u8 = undefined;
    try terminal.encodeHeader(&header, .{ .kind = .observe, .payload_len = 0 });
    try std.testing.expectEqual(framing_version, header[4]);
    try std.testing.expectError(error.UnknownKind, decodeHeader(&header));
    try encodeHeader(&header, .{ .kind = .attach_ready, .payload_len = payload_bytes.attach_ready });
    try std.testing.expectError(error.UnknownKind, terminal.decodeHeader(&header));
    var bytes: [payload_bytes.attach_ready]u8 = undefined;
    const ready = AttachReady{ .server_id = 91, .session_id = 7, .instance_id = 3, .tree_revision = 4, .client_id = 0xf123_4567_89ab_cdef };
    try encodeAttachReady(&bytes, ready);
    try std.testing.expectEqualDeep(ready, try decodeAttachReady(&bytes));
    for (0..5) |field| {
        var invalid = bytes;
        @memset(invalid[field * 8 ..][0..8], 0);
        try std.testing.expectError(error.InvalidPayload, decodeAttachReady(&invalid));
    }
    try std.testing.expectError(error.InvalidPayload, decodeAttachReady(bytes[0..24]));
}
