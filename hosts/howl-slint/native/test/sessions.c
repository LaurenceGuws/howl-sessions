/* A live, disposable Session. The caller supplies a private Server endpoint.
 * Detaching must not kill the remote child; release/reopen preserves its identity.
 * No local PTY or Instance is constructed by this client. */
#include "howl_server_client.h"
#include "remote.h"
#include "howl_server_client_render.h"
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <pthread.h>
#include <stdatomic.h>

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

struct observation {
    struct remote_client *host;
    atomic_int done;
    uint32_t status, width, height;
};
static void *observe(void *data) {
    struct observation *o = data;
    const uint8_t *pixels = NULL; int exited = 0;
    o->status = remote_step(o->host, &pixels, &o->width, &o->height, &exited);
    atomic_store(&o->done, 1);
    return NULL;
}
static int await_observation(struct observation *o) {
    for (unsigned i=0; i<200; ++i) {
        if (atomic_load(&o->done)) return 1;
        const struct timespec pause={.tv_nsec=10000000}; nanosleep(&pause,NULL);
    }
    return 0;
}

/* A rejected delivery must release its HSR lease and remain retryable. No
 * callback pointer survives the call. Repeated failures also cover cleanup. */
struct rejected_frame { unsigned calls; uint32_t width, height; };
static uint32_t reject_frame(void *context, const hrc_frame_view *view) {
    struct rejected_frame *seen = context;
    seen->calls++;
    seen->width = view->info.surface_width;
    seen->height = view->info.surface_height;
    return HSC_RESOURCE_LIMIT;
}

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: sessions-live ENDPOINT FONT_PATH\n"); return 2; }
    int result = 1;
    hsc_interrupt *interrupt = NULL;
    hsc_control *control = NULL;
    hsc_attachment *attachment = NULL;
    hsc_snapshot *snapshot = NULL;
    hsr_renderer *renderer = NULL;
    hsr_frame *frame = NULL;
    struct remote_client *host = NULL;
    struct remote_actions *actions = NULL;
    hsc_interrupt *action_interrupt = NULL;
    pthread_t observer;
    int observer_started = 0;
    struct observation observation = {0};
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
        uint16_t cw=0,ch=0;
        REQUIRE(remote_cell_size(host,&cw,&ch)==HSC_OK);
        REQUIRE(hsc_interrupt_create(HSC_ABI_VERSION,&action_interrupt)==HSC_OK);
        REQUIRE(remote_actions_open(argv[1],action_interrupt,sid,session_id,instance_id,&actions)==HSC_OK);
        REQUIRE(remote_actions_resize(actions,640,400,cw,ch)==HSC_OK);
        const uint8_t *pixels = NULL; uint32_t width = 0, height = 0; int exited = 0;
        struct rejected_frame rejected = {0};
        REQUIRE(remote_visit(host, NULL, &rejected, &exited) == HSC_INVALID_ARGUMENT);
        for (unsigned retry = 0; retry < 3; retry++) {
            REQUIRE(remote_visit(host, reject_frame, &rejected, &exited) == HSC_RESOURCE_LIMIT);
            REQUIRE(!exited);
        }
        REQUIRE(rejected.calls == 3 && rejected.width && rejected.height);
        REQUIRE(remote_step(host, &pixels, &width, &height, &exited) == HSC_OK);
        REQUIRE(pixels && width && height && width <= 640 && height <= 400 && !exited);
        /* Drain any already-published shell output, then prove idle observation
         * stays parked. Only the observer owner calls remote_step. */
        int parked=0;
        for(unsigned attempt=0;attempt<20 && !parked;attempt++) {
            observation=(struct observation){.host=host};
            REQUIRE(pthread_create(&observer,NULL,observe,&observation)==0);
            observer_started=1;
            const struct timespec pause={.tv_nsec=100000000}; nanosleep(&pause,NULL);
            if(atomic_load(&observation.done)) {
                REQUIRE(pthread_join(observer,NULL)==0); observer_started=0;
                REQUIRE(observation.status==HSC_OK);
            } else parked=1;
        }
        REQUIRE(parked);
        REQUIRE(remote_actions_key(actions,HSC_KEY_ENTER,0,HSC_KEY_PRESS,0)==HSC_OK);
        REQUIRE(await_observation(&observation));
        REQUIRE(pthread_join(observer,NULL)==0); observer_started=0;
        REQUIRE(observation.status==HSC_OK);
        observation=(struct observation){.host=host};
        REQUIRE(pthread_create(&observer,NULL,observe,&observation)==0); observer_started=1;
        REQUIRE(remote_actions_resize(actions,720,440,cw,ch)==HSC_OK);
        REQUIRE(await_observation(&observation));
        REQUIRE(pthread_join(observer,NULL)==0); observer_started=0;
        REQUIRE(observation.status==HSC_OK);
        /* A queued input publication may precede resize. Wait for the exact new
         * surface rather than assume response ordering across two connections. */
        while(observation.width != (720/cw)*cw || observation.height != (440/ch)*ch) {
            observation=(struct observation){.host=host};
            REQUIRE(pthread_create(&observer,NULL,observe,&observation)==0); observer_started=1;
            REQUIRE(await_observation(&observation));
            REQUIRE(pthread_join(observer,NULL)==0); observer_started=0;
            REQUIRE(observation.status==HSC_OK);
        }
        /* Large and tall viewports must use the canonical cell budget, not
         * the old 160x80 host clamp. Shrinking then growing must reflow too. */
        const uint32_t sizes[][2] = {{3448, 970}, {1300, 2200}, {640, 400}, {3448, 970}, {UINT32_MAX, UINT32_MAX}};
        for (size_t size = 0; size < sizeof(sizes) / sizeof(sizes[0]); size++) {
            uint32_t columns = sizes[size][0] / cw, rows = sizes[size][1] / ch;
            if (columns > HRC_MAX_COLUMNS) columns = HRC_MAX_COLUMNS;
            if (rows > HRC_MAX_ROWS) rows = HRC_MAX_ROWS;
            if (columns > 4096u / cw) columns = 4096u / cw;
            if (rows > 4096u / ch) rows = 4096u / ch;
            REQUIRE(remote_actions_resize(actions,sizes[size][0],sizes[size][1],cw,ch)==HSC_OK);
            do {
                observation=(struct observation){.host=host};
                REQUIRE(pthread_create(&observer,NULL,observe,&observation)==0); observer_started=1;
                REQUIRE(await_observation(&observation));
                REQUIRE(pthread_join(observer,NULL)==0); observer_started=0;
                REQUIRE(observation.status==HSC_OK);
            } while(observation.width != columns*cw || observation.height != rows*ch);
            REQUIRE(observation.width <= 4096 && observation.height <= 4096);
            printf("GEOMETRY_PASS viewport=%ux%u grid=%ux%u raster=%ux%u\n",
                sizes[size][0], sizes[size][1], columns, rows, observation.width, observation.height);
            if (size == 0) REQUIRE(columns > 160);
            if (size == 1) REQUIRE(rows > 80);
        }
        REQUIRE(remote_actions_resize(actions,640,400,0,ch)==HSC_INVALID_ARGUMENT);
        REQUIRE(remote_actions_resize(actions,640,400,cw,0)==HSC_INVALID_ARGUMENT);
        REQUIRE(remote_actions_resize(actions,UINT32_MAX,UINT32_MAX,4097,ch)==HSC_RESOURCE_LIMIT);
        /* An unallocated/hidden viewport never replaces canonical geometry. */
        REQUIRE(remote_actions_resize(actions,0,0,cw,ch)==HSC_OK);
        /* A DPI-sized renderer needs a physical frame wider than the old
         * 2048 limit. Recreate only this observer; the remote shell survives. */
        REQUIRE(remote_attach(host, sid, session_id, instance_id, faces, NULL, 0, 32) == HSC_OK);
        REQUIRE(remote_cell_size(host,&cw,&ch)==HSC_OK);
        REQUIRE(cw > 0 && 2140/cw <= 160);
        REQUIRE(remote_actions_resize(actions,2140,440,cw,ch)==HSC_OK);
        do {
            observation=(struct observation){.host=host};
            REQUIRE(pthread_create(&observer,NULL,observe,&observation)==0); observer_started=1;
            REQUIRE(await_observation(&observation));
            REQUIRE(pthread_join(observer,NULL)==0); observer_started=0;
            REQUIRE(observation.status==HSC_OK);
        } while(observation.width != (2140/cw)*cw || observation.height != (440/ch)*ch);
        REQUIRE(observation.width > 2048);
        parked=0;
        for(unsigned attempt=0;attempt<20 && !parked;attempt++) {
            observation=(struct observation){.host=host};
            REQUIRE(pthread_create(&observer,NULL,observe,&observation)==0); observer_started=1;
            const struct timespec pause={.tv_nsec=100000000}; nanosleep(&pause,NULL);
            if(atomic_load(&observation.done)) {
                REQUIRE(pthread_join(observer,NULL)==0); observer_started=0;
                REQUIRE(observation.status==HSC_OK);
            } else parked=1;
        }
        REQUIRE(parked);
        /* Cancel a parked observer only; the action connection remains usable. */
        REQUIRE(hsc_interrupt_cancel(interrupt)==HSC_OK);
        REQUIRE(await_observation(&observation));
        REQUIRE(pthread_join(observer,NULL)==0); observer_started=0;
        REQUIRE(observation.status==HSC_CANCELLED);
        REQUIRE(remote_actions_key(actions,HSC_KEY_ENTER,0,HSC_KEY_PRESS,0)==HSC_OK);
        REQUIRE(remote_actions_resize(actions,640,400,cw,ch)==HSC_OK);
        found = 1;
    }
    REQUIRE(found);
    puts("SESSIONS_LIVE_PASS: input, geometry, four-face render, parked observer wakes/cancels independently; remote child survives");
    result = 0;
done:
    if(observer_started) {
        hsc_interrupt_cancel(interrupt);
        pthread_join(observer,NULL);
    }
    remote_actions_close(actions);
    hsc_interrupt_release(&action_interrupt);
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
