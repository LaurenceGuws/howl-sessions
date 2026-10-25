#ifndef HOWL_SERVER_CLIENT_RENDER_H
#define HOWL_SERVER_CLIENT_RENDER_H
#include <stddef.h>
#include <stdint.h>
#include "howl_render_native.h"

/* Compose with the exact Server Client ABI in ONE native library. Snapshot
 * pointers from another shared library are not accepted. The C records and
 * Render resource identities are owned by canonical Howl Render. */
#define HSR_ABI_VERSION 1u
struct hsc_snapshot;
typedef struct hsr_renderer hsr_renderer;
typedef struct hsr_frame hsr_frame;
typedef struct hsr_bytes {
    const uint8_t *data;
    size_t len;
} hsr_bytes;
typedef struct hsr_config {
    hsr_bytes primary;
    const hsr_bytes *fallbacks;
    size_t fallback_count;
    uint16_t pixel_size, reserved;
} hsr_config;
enum hsr_status {
    HSR_OK=0, HSR_INVALID_ARGUMENT=1, HSR_VERSION_MISMATCH=2,
    HSR_OUT_OF_MEMORY=3, HSR_RESOURCE_LIMIT=4, HSR_BUSY=5,
    HSR_UNSUPPORTED_IMAGES=6, HSR_RENDER_FAILED=7
};
#ifdef __cplusplus
extern "C" {
#endif
uint32_t hsr_abi_version(void);
/* Serial producer only. Font paths borrow the call and are copied by Text.
 * Up to 24 fallback paths share the same pixel size and family metrics.
 * Failed constructors leave a NULL output slot. The renderer has a private
 * resource namespace and exactly one outstanding immutable frame lease. */
uint32_t hsr_create(uint32_t version, const hsr_config *, hsr_renderer **out);
/* BUSY preserves the owner; NULL slot/value is a successful no-op. */
uint32_t hsr_try_destroy(hsr_renderer **owner);
uint32_t hsr_cell_size(const hsr_renderer *, hrc_cell_size *out);
/* One already-observed immutable snapshot. Source remains owned by Client,
 * and is borrowed only during the call. Caller supplies TRUE backend
 * residency, not merely uploads emitted by a prior frame.
 * Rejected images are explicit until the host image-fetch lane is wired.
 * The output slot starts NULL and remains NULL on every failure. */
uint32_t hsr_capture(hsr_renderer *, const struct hsc_snapshot *,
    const hrc_residency *, size_t count, hsr_frame **out);
/* Borrowed records and pixel pointers expire at frame release, not at the
 * next Client observation. Backend upload/application must finish first. */
uint32_t hsr_frame_read(const hsr_frame *, hrc_frame_view *out);
void hsr_frame_release(hsr_frame **frame);
#ifdef __cplusplus
}
#endif
#endif
