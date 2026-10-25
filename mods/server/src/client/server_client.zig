//! Curated native Server client API; storage and transport stay private.
const impl = @import("control_owner");

/// Pure Server control and attachment wire vocabulary.
pub const protocol = @import("server_protocol");
/// Established terminal interaction and immutable observation APIs.
pub const terminal = @import("terminal_client");
/// Complete bounded connection/control/admission error set.
pub const Error = impl.Error;
/// Native construction diagnostic stage.
pub const ConnectStage = impl.ConnectStage;
/// Bounded native construction diagnostic.
pub const ConnectDiagnostic = impl.ConnectDiagnostic;
/// Caller-owned cross-thread construction and I/O interrupt.
pub const Interrupt = impl.Interrupt;
/// Independent owned wake capability for an established stream.
pub const Cancellation = impl.Cancellation;
/// Exact nonzero Server/Session/Instance endpoint selection.
pub const Target = impl.Target;
/// Opaque Server catalog and CRUD connection.
pub const Connection = impl.Connection;
/// Independently owned decoded catalog with explicit release.
pub const Tree = impl.Tree;
/// Opens one complete dedicated terminal attachment, leaving catalog control separate.
pub const attach = impl.attach;
