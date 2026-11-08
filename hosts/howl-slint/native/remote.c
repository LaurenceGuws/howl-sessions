#define _POSIX_C_SOURCE 200809L
#include "remote.h"
#include "howl_server_client_render.h"
#include "cpu.h"
#include <stdlib.h>
#include <string.h>

#define MAX_TARGETS 256u
struct remote_target { size_t session_index, instance_index; uint64_t session, instance; };
struct remote_client {
    hsc_control *control;
    hsc_tree *tree;
    hsc_attachment *attachment;
    hsc_interrupt *interrupt; /* Borrowed until worker finishes. */
    hsr_renderer *renderer;
    hrc_cell_size cell;
    struct cpu_surface surface;
    char *endpoint;
    uint64_t server;
    struct remote_target targets[MAX_TARGETS];
    size_t count;
};
uint32_t remote_close(struct remote_client *p) {
    if (!p) return HSC_OK;
    hsc_attachment_release(&p->attachment);
    uint32_t status = hsr_try_destroy(&p->renderer);
    if (status) return 100 + status;
    hsc_tree_release(&p->tree);
    hsc_control_release(&p->control);
    free(p->endpoint);
    free(p->surface.pixels);
    free(p);
    return HSC_OK;
}
uint32_t remote_open(const char *endpoint, hsc_interrupt *interrupt, struct remote_client **out) {
    if (!endpoint || !out || *out) return HSC_INVALID_ARGUMENT;
    struct remote_client *p = calloc(1, sizeof(*p));
    if (!p) return HSC_OUT_OF_MEMORY;
    uint32_t status = HSC_OUT_OF_MEMORY;
    p->interrupt = interrupt;
    p->endpoint = strdup(endpoint);
    p->surface.pixels = malloc(CPU_MAX_SIDE * CPU_MAX_SIDE * 4u);
    if (!p->endpoint || !p->surface.pixels) goto fail;
    status = hsc_control_open(HSC_ABI_VERSION, (const uint8_t *)endpoint, strlen(endpoint), interrupt, &p->control);
    if (status) goto fail;
    status = hsc_control_tree(p->control, 0, &p->tree);
    if (status) goto fail;
    hsc_server_status server = {0};
    status = hsc_tree_status(p->tree, &server);
    if (status) goto fail;
    p->server = server.server_id;
    for (size_t s = 0; s < server.session_count; s++) {
        hsc_session session = {0};
        status = hsc_tree_session(p->tree, s, &session);
        if (status) goto fail;
        for (size_t i = 0; i < session.instance_count; i++) {
            hsc_instance instance = {0};
            status = hsc_tree_instance(p->tree, s, i, &instance);
            if (status) goto fail;
            if (instance.state != HSC_INSTANCE_RUNNING) continue;
            if (p->count == MAX_TARGETS) { status = HSC_RESOURCE_LIMIT; goto fail; }
            p->targets[p->count++] = (struct remote_target){s, i, session.id, instance.id};
        }
    }
    *out = p;
    return HSC_OK;
fail:
    remote_close(p);
    return status;
}
size_t remote_count(const struct remote_client *p) { return p->count; }
uint32_t remote_item(const struct remote_client *p, size_t index, char *name, size_t capacity,
                     size_t *length, uint64_t *server, uint64_t *session, uint64_t *instance) {
    if (index >= p->count || !name || !length || !server || !session || !instance) return HSC_INVALID_ARGUMENT;
    const struct remote_target *target = &p->targets[index];
    hsc_session row = {0};
    uint32_t status = hsc_tree_session(p->tree, target->session_index, &row);
    if (status) return status;
    if (row.name_len > capacity) return HSC_BUFFER_TOO_SMALL;
    memcpy(name, row.name, row.name_len);
    *length = row.name_len;
    *server = p->server;
    *session = target->session;
    *instance = target->instance;
    return HSC_OK;
}
uint32_t remote_attach(struct remote_client *p, uint64_t server, uint64_t session, uint64_t instance,
                       const char *const *fonts, const char *const *fallbacks, size_t count, uint16_t pixels) {
    if (count > 24 || !fonts || !fonts[0]) return HSC_INVALID_ARGUMENT;
    hsc_attachment_release(&p->attachment);
    uint32_t status = hsr_try_destroy(&p->renderer);
    if (status) return 100 + status;
    hsr_bytes fallback[24];
    for (size_t i = 0; i < count; i++) fallback[i] = (hsr_bytes){(const uint8_t *)fallbacks[i], strlen(fallbacks[i])};
    hsr_family_config config = {.pixel_size = pixels};
    for (size_t i = 0; i < 4; i++) if (fonts[i]) {
        config.fonts[i].primary = (hsr_bytes){(const uint8_t *)fonts[i], strlen(fonts[i])};
        config.fonts[i].fallbacks = fallback;
        config.fonts[i].fallback_count = count;
    }
    status = hsr_create_family(HSR_ABI_VERSION, &config, &p->renderer);
    if (status) return 100 + status;
    status = hsr_cell_size(p->renderer, &p->cell);
    if (status) return 100 + status;
    return hsc_attachment_open(HSC_ABI_VERSION, (const uint8_t *)p->endpoint, strlen(p->endpoint),
        server, session, instance, p->interrupt, &p->attachment);
}
uint32_t remote_key(struct remote_client *p, uint8_t key, uint32_t scalar, uint8_t action, uint8_t mods) {
    if (!p->attachment) return HSC_UNAVAILABLE;
    return key ? hsc_named_key(p->attachment, key, action, mods) : hsc_unicode_key(p->attachment, scalar, action, mods);
}
uint32_t remote_resize(struct remote_client *p, uint32_t width, uint32_t height) {
    if (!p->attachment) return HSC_UNAVAILABLE;
    if (width < p->cell.width || height < p->cell.height) return HSC_OK;
    uint32_t columns = width / p->cell.width, rows = height / p->cell.height;
    if (columns > 160) columns = 160;
    if (rows > 80) rows = 80;
    if (columns * p->cell.width > CPU_MAX_SIDE || rows * p->cell.height > CPU_MAX_SIDE) return HSC_RESOURCE_LIMIT;
    hsc_geometry geometry = {(uint16_t)rows, (uint16_t)columns, p->cell.width, p->cell.height};
    return hsc_resize_geometry(p->attachment, &geometry, 1);
}
uint32_t remote_step(struct remote_client *p, const uint8_t **pixels, uint32_t *width, uint32_t *height, int *exited) {
    *pixels = NULL;
    *exited = 0;
    if (!p->attachment) return HSC_UNAVAILABLE;
    hsc_snapshot *snapshot = NULL;
    hsr_frame *frame = NULL;
    uint32_t status = hsc_observe(p->attachment, 0, 0, &snapshot);
    if (status) return status;
    hsc_metadata meta = {0};
    status = hsc_snapshot_metadata(snapshot, &meta);
    if (status) goto done;
    *exited = (meta.flags & 8) != 0;
    status = hsr_capture(p->renderer, snapshot, NULL, 0, &frame);
    if (status) { status += 100; goto done; }
    hrc_frame_view view = {0};
    status = hsr_frame_read(frame, &view);
    if (status) { status += 100; goto done; }
    if (cpu_paint(&p->surface, &view.info, view.commands, view.uploads)) { status = HSC_PROTOCOL_ERROR; goto done; }
    *pixels = p->surface.pixels;
    *width = p->surface.width;
    *height = p->surface.height;
done:
    hsr_frame_release(&frame);
    hsc_snapshot_release(&snapshot);
    return status;
}
