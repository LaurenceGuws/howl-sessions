//! Transport-neutral terminal observation encoding and validation.
//!
//! Observation values belong to the protocol, while the encoder borrows one
//! canonical VT observation directly. Neither owns a terminal, grid, connection,
//! process, or rendered frame; a second representation would duplicate authority.
const std = @import("std");
const wire = @import("observation_codec/wire.zig");

/// Terminal-only metadata grammar with no Server observation or authority state.
pub const metadata = @import("observation_codec/metadata.zig");
/// VT semantic revision, history, viewport and cursor facts for one observation.
pub const Metadata = metadata.Metadata;

/// Transport-free terminal value decoding and allocation lifetime.
pub const decoded = @import("observation_codec/decoded.zig");

/// Complete owned text observations with bounded raw/zlib/packed decoding.
pub const text = @import("observation_codec/text.zig");

/// Complete/raw-delta text reuse, validation and borrowed observation lifetime.
pub const cache = @import("observation_codec/cache.zig");

/// Immutable terminal observations, packed storage and bounded text projection.
pub const view = @import("observation_codec/view.zig");

/// Read-only VT encoding and optional retained terminal delta rows.
pub const encoder = @import("observation_codec/encode.zig");

/// Complete bounded terminal properties; decoded slices borrow their packet.
pub const properties = wire.properties;

/// Hard ceiling for one complete encoded/decoded semantic text observation.
pub const maximum_text_snapshot_bytes = wire.maximum_text_snapshot_bytes;

/// Rejects malformed or noncanonical observation payloads.
pub const PayloadError = wire.PayloadError;

/// Self-delimiting record tags shared by full and explicit delta observations.
pub const TextRecordKind = wire.TextRecordKind;

/// One self-delimiting `text_v1` record header. Reserved bytes are always zero.
pub const TextRecordHeader = wire.TextRecordHeader;

/// Stable language-neutral terminal color classes used by `text_v1` cells.
pub const TextColorKind = wire.TextColorKind;

/// One semantic terminal color. RGB values use the low 24 bits as 0xRRGGBB.
pub const TextColor = wire.TextColor;

/// Frozen byte grammar and bounds for the renderer-neutral rich text snapshot.
pub const text_v1 = wire.text_v1;

/// Frozen delta-only additions layered over complete `text_v1` records.
///
/// Every framing-v7 `snapshot_delta_data` body carries exactly one row-shift
/// record after presentation and before rows. Zero means no viewport movement;
/// positive values rotate the named baseline upward before row reuse markers
/// are interpreted. Complete raw/compressed `text_v1` bodies never carry it.
pub const text_delta_v2 = wire.text_delta_v2;

/// Lossless transport packing for complete `text_v1` bodies.
///
/// This is not a second semantic terminal representation. Record headers,
/// presentation bytes, hyperlink bytes, cell attributes and Unicode scalars
/// reconstruct byte-for-byte to the frozen `text_v1` grammar before semantic
/// decoding. Only complete row payload carriage changes.
pub const text_pack_v1 = wire.text_pack_v1;

/// Frozen image-resource and visible-placement grammar introduced with framing v4.
///
/// `text_v1` remains byte-for-byte unchanged. A snapshot carries one separate
/// `snapshot_graphics` frame containing only lightweight resource identities and
/// visible placements. Exact RGBA8 pixels are fetched on demand by image id and
/// content generation, so the 4 MiB snapshot bound never competes with the
/// canonical terminal's larger decoded-image quota.
pub const graphics_v2 = wire.graphics_v2;

/// Snapshot graphics prefix shared by the lightweight manifest codecs.
pub const SnapshotGraphicsHeader = wire.SnapshotGraphicsHeader;

/// One image resource identity referenced by a visible placement.
pub const SnapshotImage = wire.SnapshotImage;

/// One image placement resolved into the current snapshot viewport.
pub const SnapshotImagePlacement = wire.SnapshotImagePlacement;

/// Encodes one self-delimiting `text_v1` record header.
pub const encodeTextRecordHeader = wire.encodeTextRecordHeader;

/// Decodes one `text_v1` record header and rejects every reserved bit.
pub const decodeTextRecordHeader = wire.decodeTextRecordHeader;

/// Exact failure surface for lossless text_v1 transport packing/unpacking.
pub const TextPackError = wire.TextPackError;

/// Packs one complete frozen `text_v1` body without changing its semantics.
/// Rows use consecutive exact attribute runs only when that representation is
/// smaller; otherwise the original row payload is carried verbatim.
pub const packTextV1 = wire.packTextV1;

/// Reconstructs the exact frozen `text_v1` body from `text_pack_v1` carriage.
/// The caller supplies the exact expected original byte count from the transport
/// envelope; hostile input cannot grow beyond that bound.
pub const unpackTextV1 = wire.unpackTextV1;

/// Encodes the explicit framing-v7 delta baseline rotation.
pub const encodeTextRowShift = wire.encodeTextRowShift;

/// Decodes the exact two-byte framing-v7 delta baseline rotation.
pub const decodeTextRowShift = wire.decodeTextRowShift;

/// Encodes one semantic `text_v1` terminal color.
pub const encodeTextColor = wire.encodeTextColor;

/// Decodes and validates one semantic `text_v1` terminal color.
pub const decodeTextColor = wire.decodeTextColor;

/// Encodes the fixed prefix of one snapshot graphics manifest.
pub const encodeSnapshotGraphicsHeader = wire.encodeSnapshotGraphicsHeader;

/// Decodes the fixed prefix of one bounded snapshot graphics manifest.
pub const decodeSnapshotGraphicsHeader = wire.decodeSnapshotGraphicsHeader;

/// Encodes one visible image resource descriptor.
pub const encodeSnapshotImage = wire.encodeSnapshotImage;

/// Decodes one visible image resource descriptor.
pub const decodeSnapshotImage = wire.decodeSnapshotImage;

/// Encodes one image placement resolved into the snapshot viewport.
pub const encodeSnapshotImagePlacement = wire.encodeSnapshotImagePlacement;

/// Decodes one image placement resolved into the snapshot viewport.
pub const decodeSnapshotImagePlacement = wire.decodeSnapshotImagePlacement;

/// Decoded terminal observation value.
pub const Geometry = decoded.Geometry;

/// Decoded terminal observation value.
pub const Rgba = decoded.Rgba;

/// Decoded terminal observation value.
pub const Presentation = decoded.Presentation;

/// Decoded terminal observation value.
pub const Cell = decoded.Cell;

/// Decoded terminal observation value.
pub const Row = decoded.Row;

/// Decoded terminal observation value.
pub const Hyperlink = decoded.Hyperlink;

/// Decoded terminal observation value.
pub const Graphics = decoded.Graphics;

/// Allocation or malformed semantic observation failures.
pub const DecodeError = decoded.Error;

test {
    std.testing.refAllDecls(wire);
    std.testing.refAllDecls(metadata);
    std.testing.refAllDecls(decoded);
    std.testing.refAllDecls(text);
    std.testing.refAllDecls(cache);
    std.testing.refAllDecls(view);
    std.testing.refAllDecls(encoder);
}
