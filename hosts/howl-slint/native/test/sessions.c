/* A live, disposable Session. The caller supplies a private Server endpoint.
 * Detaching must not kill the remote child; release/reopen preserves its identity.
 * No local PTY or Instance is constructed by this client. */
#include "howl_server_client.h"
#include "remote.h"
#include "howl_server_client_render.h"
#include <stdio.h>
#include <string.h>
#include <time.h>

#define REQUIRE(ok) do { if (!(ok)) { fprintf(stderr, "failed line %d: %s\n", __LINE__, #ok); goto done; } } while (0)

static int contains(const hsc_snapshot *snapshot, const char *needle) {
    const uint32_t *scalars = NULL;
    size_t length = 0, n = strlen(needle);
    if (hsc_snapshot_scalars(snapshot, &scalars, &length) != HSC_OK) return 0;
    for (size_t i = 0; i + n <= length; ++i) {
        size_t j = 0;
        while (j < n && scalars[i + j] == (unsigned char)needle[j]) ++j;
        if (j == n) return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 3 && !(argc == 4 && !strcmp(argv[3], "--benchmark"))) { fprintf(stderr, "usage: sessions-live ENDPOINT FONT_PATH [--benchmark]\n"); return 2; }
    int result = 1;
    hsc_interrupt *interrupt = NULL;
    hsc_control *control = NULL;
    hsc_attachment *attachment = NULL;
    hsc_snapshot *snapshot = NULL;
    hsr_renderer *renderer = NULL;
    hsr_frame *frame = NULL;
    struct remote_client *host = NULL;
    uint64_t session = 0;
    hsc_identity identity = {0};
    const uint8_t *endpoint = (const uint8_t *)argv[1];
    size_t endpoint_len = strlen(argv[1]);
    REQUIRE(hsc_interrupt_create(HSC_ABI_VERSION, &interrupt) == HSC_OK);
    REQUIRE(hsc_control_open(HSC_ABI_VERSION, endpoint, endpoint_len, NULL, &control) == HSC_OK);
    hsc_server_status server = {0};
    REQUIRE(hsc_control_status(control, &server) == HSC_OK);
    char name[64];
    snprintf(name, sizeof(name), "slint-live-%llu", (unsigned long long)time(NULL));
    REQUIRE(hsc_session_create(control, (const uint8_t *)name, strlen(name), &session) == HSC_OK);
    const char *shell = "/bin/sh", *command = "exec /bin/sh -i";
    hsc_launch launch = { .session_id = session, .rows = 24, .columns = 80, .history_rows = 32,
        .shell = (const uint8_t *)shell, .shell_len = strlen(shell),
        .command = (const uint8_t *)command, .command_len = strlen(command) };
    REQUIRE(hsc_instance_create(control, &launch, &identity) == HSC_OK);
    REQUIRE(hsc_attachment_open(HSC_ABI_VERSION, endpoint, endpoint_len, server.server_id,
        session, identity.instance_id, interrupt, &attachment) == HSC_OK);
    hsr_family_config fonts = {.pixel_size = 16};
    for (size_t i = 0; i < 4; i++) fonts.fonts[i].primary = (hsr_bytes){(const uint8_t *)argv[2], strlen(argv[2])};
    REQUIRE(hsr_create_family(HSR_ABI_VERSION, &fonts, &renderer) == HSR_OK);
    hrc_cell_size cell = {0};
    REQUIRE(hsr_cell_size(renderer, &cell) == HSR_OK);
    hsc_geometry geometry = {.rows = 20, .columns = 72, .cell_pixel_width = cell.width, .cell_pixel_height = cell.height};
    REQUIRE(hsc_resize_geometry(attachment, &geometry, 1) == HSC_OK);
    /* Marker does not occur contiguously in the echoed command. */
    const char *input = "printf 'REMOTE_%s_OK\\n' SURVIVES\n";
    REQUIRE(hsc_text(attachment, (const uint8_t *)input, strlen(input), 0) == HSC_OK);
    int observed = 0;
    for (size_t i = 0; i < 100 && !observed; i++) {
        hsc_snapshot_release(&snapshot);
        REQUIRE(hsc_observe(attachment, 0, 0, &snapshot) == HSC_OK);
        observed = contains(snapshot, "REMOTE_SURVIVES_OK");
        if (!observed) { const struct timespec wait = {.tv_nsec = 10000000}; nanosleep(&wait, NULL); }
    }
    REQUIRE(observed);
    REQUIRE(hsr_capture(renderer, snapshot, NULL, 0, &frame) == HSR_OK);
    hrc_frame_view view = {0};
    REQUIRE(hsr_frame_read(frame, &view) == HSR_OK);
    REQUIRE(view.info.command_count && view.info.surface_width == 72 * cell.width && view.info.surface_height == 20 * cell.height);
    hsr_frame_release(&frame);
    hsc_snapshot_release(&snapshot);
    hsc_attachment_release(&attachment);
    /* Re-attach, not restart. The Server remains owner while this client leaves. */
    REQUIRE(hsc_attachment_open(HSC_ABI_VERSION, endpoint, endpoint_len, server.server_id,
        session, identity.instance_id, interrupt, &attachment) == HSC_OK);
    REQUIRE(hsc_observe(attachment, 0, 0, &snapshot) == HSC_OK);
    hsc_metadata meta = {0};
    REQUIRE(hsc_snapshot_metadata(snapshot, &meta) == HSC_OK);
    REQUIRE(!(meta.flags & 8) && contains(snapshot, "REMOTE_SURVIVES_OK"));
    hsc_snapshot_release(&snapshot);
    REQUIRE(hsc_interrupt_cancel(interrupt) == HSC_OK);
    REQUIRE(hsc_observe(attachment, 0, 0, &snapshot) == HSC_CANCELLED);
    REQUIRE(snapshot == NULL);
    hsc_attachment_release(&attachment);
    hsc_interrupt_release(&interrupt);
    REQUIRE(hsc_interrupt_create(HSC_ABI_VERSION, &interrupt) == HSC_OK);
    REQUIRE(hsc_attachment_open(HSC_ABI_VERSION, endpoint, endpoint_len, server.server_id,
        session, identity.instance_id, interrupt, &attachment) == HSC_OK);
    REQUIRE(hsc_observe(attachment, 0, 0, &snapshot) == HSC_OK);
    REQUIRE(hsc_snapshot_metadata(snapshot, &meta) == HSC_OK);
    REQUIRE(!(meta.flags & 8) && contains(snapshot, "REMOTE_SURVIVES_OK"));
    /* Exercise the exact adapter linked by the Rust host, not only core APIs. */
    REQUIRE(remote_open(argv[1], interrupt, &host) == HSC_OK);
    int found = 0;
    for (size_t i = 0; i < remote_count(host); i++) {
        char label[64]; size_t length = 0; uint64_t sid, session_id, instance_id;
        REQUIRE(remote_item(host, i, label, sizeof(label), &length, &sid, &session_id, &instance_id) == HSC_OK);
        if (session_id != session || instance_id != identity.instance_id) continue;
        REQUIRE(sid == server.server_id && length == strlen(name) && !memcmp(label, name, length));
        const char *faces[] = {argv[2], argv[2], argv[2], argv[2]};
        REQUIRE(remote_attach(host, sid, session_id, instance_id, faces, NULL, 0, 16) == HSC_OK);
        REQUIRE(remote_resize(host, 640, 400) == HSC_OK);
        const uint8_t *pixels = NULL; uint32_t width = 0, height = 0; int exited = 0;
        REQUIRE(remote_step(host, &pixels, &width, &height, &exited) == HSC_OK);
        REQUIRE(pixels && width && height && width <= 640 && height <= 400 && !exited);
        if (argc == 4) {
            /* Same live transport/capture/compositor path as the host. The loop
             * intentionally excludes UI upload, sleep and initial font setup. */
            REQUIRE(remote_resize(host, 1600, 900) == HSC_OK);
            for (unsigned mode = 0; mode < 2; mode++) {
                struct timespec wall0, wall1, cpu0, cpu1;
                clock_gettime(CLOCK_MONOTONIC, &wall0);
                clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpu0);
                for (unsigned n = 0; n < 200; n++) {
                    if (mode) REQUIRE(remote_key(host, HSC_KEY_ENTER, 0, HSC_KEY_PRESS, 0) == HSC_OK);
                    REQUIRE(remote_step(host, &pixels, &width, &height, &exited) == HSC_OK);
                    REQUIRE(pixels && !exited);
                }
                clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpu1);
                clock_gettime(CLOCK_MONOTONIC, &wall1);
                double wall = (wall1.tv_sec - wall0.tv_sec) * 1e3 + (wall1.tv_nsec - wall0.tv_nsec) / 1e6;
                double cpu = (cpu1.tv_sec - cpu0.tv_sec) * 1e3 + (cpu1.tv_nsec - cpu0.tv_nsec) / 1e6;
                printf("SESSIONS_BENCH mode=%s frames=200 width=%u height=%u wall_ms=%.3f client_cpu_ms=%.3f\n",
                    mode ? "input" : "idle", width, height, wall, cpu);
            }
        }
        REQUIRE(remote_key(host, HSC_KEY_ENTER, 0, HSC_KEY_PRESS, 0) == HSC_OK);
        found = 1;
    }
    REQUIRE(found);
    puts("SESSIONS_LIVE_PASS: input, geometry, four-face render, detach/cancel/re-attach; remote child survives");
    result = 0;
done:
    if (remote_close(host) != HSC_OK) result = 1;
    hsr_frame_release(&frame);
    hsc_snapshot_release(&snapshot);
    hsc_attachment_release(&attachment);
    if (hsr_try_destroy(&renderer) != HSR_OK) result = 1;
    if (session && hsc_session_close(control, session) != HSC_OK) result = 1;
    hsc_control_release(&control);
    hsc_interrupt_release(&interrupt);
    return result;
}
