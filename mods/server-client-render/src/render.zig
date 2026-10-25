//! Server terminal-view adapter for canonical Howl Render.
//!
//! Transported storage adapts outward to the direct renderer; canonical Render
//! never imports the Server wire or client.

const client = @import("terminal_client");
const canonical = @import("howl_render");
const semantic = canonical.adapter;
const source_client = @import("render_source.zig");
const direct = canonical.terminal;

/// Exact text package instance used by this transported Render adapter.
pub const text = canonical.text;
/// Exact shared Render limits used by this transported Render adapter.
pub const limits = canonical.limits;

/// Uses the direct renderer atlas configuration.
pub const AtlasConfig = direct.AtlasConfig;
/// Uses the direct renderer shape-cache configuration.
pub const ShapeCacheConfig = direct.ShapeCacheConfig;
/// Uses the direct renderer shape-cache usage counters.
pub const ShapeCacheUsage = direct.ShapeCacheUsage;
/// Uses the direct renderer runtime atlas errors.
pub const AtlasError = direct.AtlasError;
/// Uses the direct renderer shape-cache initialization errors.
pub const ShapeCacheInitError = direct.ShapeCacheInitError;
/// Uses the direct renderer runtime shape-cache errors.
pub const ShapeCacheError = direct.ShapeCacheError;
/// Uses the direct renderer font style variants.
pub const FontVariant = direct.FontVariant;
/// Uses the direct renderer font-family value.
pub const FontFaces = direct.FontFaces;
/// Uses the shared process render Store owner.
pub const Store = direct.Store;
/// Uses the shared Store configuration.
pub const StoreConfig = direct.StoreConfig;
/// Uses the shared Store usage counters.
pub const StoreUsage = direct.StoreUsage;
/// Uses the shared Store initialization errors.
pub const StoreInitError = direct.StoreInitError;

/// Re-exports owned transported-client view vocabulary.
pub const View = client.view;

/// Uses the shared frame color type.
pub const Color = direct.Color;
/// Uses the shared frame pixel extent.
pub const Size = direct.Size;
/// Uses the shared destination/clip rectangle.
pub const Rect = direct.Rect;
/// Uses the shared resource source rectangle.
pub const SourceRect = direct.SourceRect;
/// Uses the shared logical resource identity.
pub const ResourceId = direct.ResourceId;
/// Uses the shared resource generation type.
pub const ResourceGeneration = direct.ResourceGeneration;
/// Uses the shared resource pixel format.
pub const ResourceFormat = direct.ResourceFormat;
/// Uses the shared exact resource occurrence.
pub const ResourceRef = direct.ResourceRef;
/// Uses the shared resource sampling view.
pub const ResourceView = direct.ResourceView;
/// Uses the shared backend residency fact.
pub const Residency = direct.Residency;
/// Uses the shared frame upload descriptor.
pub const FrameResourceUpload = direct.FrameResourceUpload;
/// Uses the shared missing Host-owned resource descriptor.
pub const FrameExternalResource = direct.FrameExternalResource;
/// Uses the shared final backend command type.
pub const Command = direct.Command;
/// Uses the shared pre-projection draw-input type.
pub const Input = direct.Input;

/// Uses the shared terminal Renderer configuration.
pub const Config = direct.Config;
/// Uses the shared external-image binding value.
pub const ExternalImageBinding = direct.ExternalImageBinding;
/// Bounds simultaneously visible external terminal images.
pub const maximum_external_images = direct.maximum_external_images;
/// Bounds both glyph planes and external image resources.
pub const maximum_frame_resources = direct.maximum_frame_resources;
/// Reports exact renderer-owned upload bytes missing from backend residency.
pub const framePixelBytes = direct.framePixelBytes;
/// Uses the shared terminal Renderer owner.
pub const Renderer = direct.Renderer;
/// Uses the shared Renderer usage counters.
pub const Usage = direct.Usage;
/// Uses the shared frame scratch buffers.
pub const FrameBuffers = direct.FrameBuffers;
/// Uses the shared completed frame view.
pub const Frame = direct.Frame;
/// Uses the retained-row scene update kind.
pub const RowSceneKind = direct.RowSceneKind;
/// Uses one retained-row command span.
pub const RowSceneRow = direct.RowSceneRow;
/// Uses the shared retained-row acceleration view.
pub const RowScene = direct.RowScene;
/// Uses the shared Renderer initialization errors.
pub const InitError = direct.InitError;
/// Uses the shared Renderer operation errors.
pub const Error = direct.Error;

/// Allocates one bounded terminal Renderer and private Store.
pub const initPrivate = direct.initPrivate;
/// Allocates one reusable process render Store.
pub const initStore = direct.initStore;
/// Releases one process render Store.
pub const deinitStore = direct.deinitStore;
/// Returns the fixed Store font metrics.
pub const storeMetrics = direct.storeMetrics;
/// Reports retained Store cache usage.
pub const storeUsage = direct.storeUsage;
/// Forgets retained Store shaping knowledge.
pub const resetStore = direct.resetStore;
/// Allocates one Renderer borrowing an existing Store.
pub const initWithStore = direct.initWithStore;
/// Releases one terminal Renderer.
pub const deinit = direct.deinit;
/// Forgets the terminal atlas; shared shaping remains intact.
pub const resetCaches = direct.resetCaches;
/// Reports current Renderer usage and resource counters.
pub const usage = direct.usage;
/// Reports visible Host-owned resources missing from backend residency.
pub const missingExternalResources = direct.missingExternalResources;
/// Produces one backend-facing frame against exact residency.
pub const frame = direct.frame;
/// Validates backend resource identity, generation and extent before projection.
pub const validateResidencies = direct.validateResidencies;
/// Borrows the current retained-row acceleration view when eligible.
pub const rowScene = direct.rowScene;
/// Plans exact bindings for visible canonical VT images.
pub const planObservationImageBindings = direct.planObservationImageBindings;
/// Projects one borrowed canonical VT observation synchronously.
pub const updateObservation = direct.updateObservation;

/// Plans exact resource bindings for one transported semantic image manifest.
pub fn planExternalImageBindings(
    current: []const ExternalImageBinding,
    current_usage: Usage,
    images: []const View.Image,
    output: *[maximum_external_images]ExternalImageBinding,
) error{ ImageLimit, InvalidImageBinding, ResourceIdentityOverflow }![]const ExternalImageBinding {
    if (images.len > output.len) return error.ImageLimit;
    var normalized: [maximum_external_images]semantic.Image = undefined;
    for (images, 0..) |image, index| normalized[index] = .{
        .image_id = image.image_id,
        .generation = image.generation,
        .width = image.width,
        .height = image.height,
    };
    return semantic.planImageBindings(current, current_usage, normalized[0..images.len], output);
}

/// Replaces this renderer with one immutable owned client view.
pub fn update(owner: *Renderer, snapshot: *const View.Snapshot) Error!void {
    return semantic.updateSource(source_client.Owned, owner, snapshot, &.{});
}

/// Replaces this renderer with one already-validated borrowed rich client view.
pub fn updateRich(owner: *Renderer, snapshot: *const client.rich.View) Error!void {
    return semantic.updateSource(source_client.RichView, owner, snapshot, &.{});
}

/// Replaces this renderer with one owned client view and one exact image binding.
pub fn updateWithImageBinding(
    owner: *Renderer,
    snapshot: *const View.Snapshot,
    image_binding: ExternalImageBinding,
) Error!void {
    return updateWithImageBindings(owner, snapshot, &.{image_binding});
}

/// Replaces this renderer with one immutable owned client view and exact image bindings.
pub fn updateWithImageBindings(
    owner: *Renderer,
    snapshot: *const View.Snapshot,
    image_bindings: []const ExternalImageBinding,
) Error!void {
    return semantic.updateSource(source_client.Owned, owner, snapshot, image_bindings);
}

/// Borrowed-rich equivalent of updateWithImageBindings.
pub fn updateRichWithImageBindings(
    owner: *Renderer,
    snapshot: *const client.rich.View,
    image_bindings: []const ExternalImageBinding,
) Error!void {
    return semantic.updateSource(source_client.RichView, owner, snapshot, image_bindings);
}
