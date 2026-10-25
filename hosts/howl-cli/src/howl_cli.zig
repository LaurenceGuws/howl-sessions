//! Native human/agent client for one concrete Howl Instance.

/// Version advertised by this CLI package.
pub const version = "0.1.6-dev";
/// Schema identity for machine-readable CLI version output.
pub const version_schema = "howl.version/v1";

/// Compact snapshot requests and CLI output formats.
pub const snapshot = @import("snapshot.zig");
/// Interaction-state observation and CLI output.
pub const state = @import("state.zig");
/// Semantic actions and command-line vocabulary validation.
pub const actions = @import("actions.zig");
