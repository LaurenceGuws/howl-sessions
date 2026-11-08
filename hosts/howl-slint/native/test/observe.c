/* Run a caller-selected finite workload in a disposable Server Session.
 * Measures native snapshot/capture/composition, not Slint or displayed FPS. */
#define _POSIX_C_SOURCE 200809L
#include "howl_server_client.h"
#include "howl_server_client_render.h"
#include "cpu.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <time.h>
#include <pthread.h>
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "workload line %d: %s\n", __LINE__, #x); goto done; } } while (0)
static double milliseconds(clockid_t clock) {
    struct timespec now; clock_gettime(clock, &now);
    return now.tv_sec * 1000.0 + now.tv_nsec / 1000000.0;
}
/* Test-only composition of released ABIs. No observation-mode switch is
 * introduced into the product, and all rendering uses its existing compositor. */
struct observer {
    hsc_attachment *attachment;
    hsc_cache *cache;
    hsr_renderer *renderer;
    struct cpu_surface surface;
    size_t capacity;
    uint64_t revision;
    double observe_wall, observe_cpu, capture_cpu, paint_cpu;
};
static uint32_t observe_step(struct observer *p, int *exited) {
    hsc_snapshot *snapshot = NULL;
    hsr_frame *frame = NULL;
    double wall = milliseconds(CLOCK_MONOTONIC), cpu = milliseconds(CLOCK_THREAD_CPUTIME_ID);
    uint32_t status = p->cache ? hsc_observe_cached(p->attachment, p->cache, p->revision, 0, &snapshot)
                             : hsc_observe(p->attachment, p->revision, 0, &snapshot);
    p->observe_wall = milliseconds(CLOCK_MONOTONIC) - wall;
    p->observe_cpu = milliseconds(CLOCK_THREAD_CPUTIME_ID) - cpu;
    if (status) return status;
    hsc_metadata meta = {0};
    status = hsc_snapshot_metadata(snapshot, &meta);
    if (status) goto done;
    *exited = (meta.flags & 8) != 0;
    cpu = milliseconds(CLOCK_THREAD_CPUTIME_ID);
    status = hsr_capture(p->renderer, snapshot, NULL, 0, &frame);
    if (status) { status += 100; goto done; }
    hrc_frame_view view = {0};
    status = hsr_frame_read(frame, &view);
    if (status) { status += 100; goto done; }
    p->capture_cpu = milliseconds(CLOCK_THREAD_CPUTIME_ID) - cpu;
    size_t width = view.info.surface_width, height = view.info.surface_height;
    if (!width || !height || width > CPU_MAX_SIDE || height > CPU_MAX_SIDE || width > CPU_MAX_PIXELS / height) {
        status = HSC_RESOURCE_LIMIT; goto done;
    }
    size_t bytes = width * height * 4;
    if (bytes > p->capacity) {
        void *grown = realloc(p->surface.pixels, bytes);
        if (!grown) { status = HSC_OUT_OF_MEMORY; goto done; }
        p->surface.pixels = grown; p->capacity = bytes;
    }
    cpu = milliseconds(CLOCK_THREAD_CPUTIME_ID);
    if (cpu_paint(&p->surface, &view.info, view.commands, view.uploads)) { status = HSC_PROTOCOL_ERROR; goto done; }
    p->paint_cpu = milliseconds(CLOCK_THREAD_CPUTIME_ID) - cpu;
    p->revision = meta.delivery_revision;
done:
    hsr_frame_release(&frame);
    hsc_snapshot_release(&snapshot);
    return status;
}

static int render_fixture(hsc_snapshot *snapshot, const char *font, uint16_t pixels, struct cpu_surface *surface) {
    hsr_renderer *renderer=NULL;
    hsr_frame *frame=NULL;
    hsr_family_config config={.pixel_size=pixels};
    for(unsigned i=0;i<4;i++) config.fonts[i].primary=(hsr_bytes){(const uint8_t *)font,strlen(font)};
    int result=1;
    if(hsr_create_family(HSR_ABI_VERSION,&config,&renderer) || hsr_capture(renderer,snapshot,NULL,0,&frame)) goto done;
    hrc_frame_view view={0};
    if(hsr_frame_read(frame,&view)) goto done;
    size_t width=view.info.surface_width,height=view.info.surface_height;
    if(!width || !height || width>CPU_MAX_SIDE || height>CPU_MAX_SIDE || width>CPU_MAX_PIXELS/height) goto done;
    surface->pixels=malloc(width*height*4);
    if(!surface->pixels || cpu_paint(surface,&view.info,view.commands,view.uploads)) goto done;
    result=0;
done:
    hsr_frame_release(&frame);
    if(hsr_try_destroy(&renderer)) result=1;
    return result;
}
/* Compare a quiescent exited screen, not unrelated live delivery revisions.
 * Cache snapshots must remain valid after cache release. A new attachment must
 * not inherit decoding authority from an old connection. */
static int parity(hsc_attachment *attachment, hsc_attachment *other, const char *font, uint16_t pixels) {
    hsc_snapshot *packed=NULL, *cached=NULL, *attempt=NULL;
    hsc_cache *cache=NULL;
    hsc_cell *a=NULL, *b=NULL;
    struct cpu_surface image_a={0},image_b={0};
    int result=1;
    if (hsc_cache_create(HSC_ABI_VERSION,attachment,&cache)) goto done;
    if (hsc_observe_cached(other,cache,0,0,&attempt)!=HSC_INVALID_ARGUMENT || attempt) goto done;
    if (hsc_observe(attachment,0,0,&packed) || hsc_observe_cached(attachment,cache,0,0,&cached)) goto done;
    hsc_cache_release(&cache);
    hsc_metadata x={0},y={0};
    if(hsc_snapshot_metadata(packed,&x) || hsc_snapshot_metadata(cached,&y)) goto done;
    if(x.terminal_revision!=y.terminal_revision || x.rows!=y.rows || x.columns!=y.columns ||
       x.cell_count!=y.cell_count || x.scalar_count!=y.scalar_count || x.cursor_row!=y.cursor_row ||
       x.cursor_column!=y.cursor_column || x.flags!=y.flags) goto done;
    a=calloc(x.cell_count,sizeof(*a)); b=calloc(x.cell_count,sizeof(*b));
    if(!a || !b) goto done;
    size_t na=0,nb=0;
    if(hsc_snapshot_cells(packed,0,a,x.cell_count,&na) || hsc_snapshot_cells(cached,0,b,x.cell_count,&nb) ||
       na!=nb || memcmp(a,b,na*sizeof(*a))) goto done;
    const uint32_t *sa=NULL,*sb=NULL;
    if(hsc_snapshot_scalars(packed,&sa,&na) || hsc_snapshot_scalars(cached,&sb,&nb) ||
       na!=nb || (na && memcmp(sa,sb,na*sizeof(*sa)))) goto done;
    /* Visible/blinking cursor age differs between observations. Pixel equality
     * is meaningful only for the explicitly hidden-cursor static fixture. */
    if(!(x.flags & 1)) {
        if(render_fixture(packed,font,pixels,&image_a) || render_fixture(cached,font,pixels,&image_b) ||
           image_a.width!=image_b.width || image_a.height!=image_b.height ||
           memcmp(image_a.pixels,image_b.pixels,(size_t)image_a.width*image_a.height*4)) goto done;
        printf("OBSERVATION_PIXEL_PARITY equal=1 scalars=%u cursor=hidden\n",x.scalar_count);
    }
    if(hsc_cache_create(HSC_ABI_VERSION,other,&cache) || hsc_observe_cached(other,cache,0,0,&attempt)) goto done;
    result=0;
done:
    free(image_a.pixels); free(image_b.pixels);
    free(a); free(b);
    hsc_snapshot_release(&packed); hsc_snapshot_release(&cached); hsc_snapshot_release(&attempt);
    hsc_cache_release(&cache);
    return result;
}

/* A real deadline must wake a blocked observation, not just guard its loop. */
struct deadline {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    int finished;
    hsc_interrupt *interrupt;
};
static void *deadline_run(void *data) {
    struct deadline *d=data;
    struct timespec until; clock_gettime(CLOCK_MONOTONIC,&until); until.tv_sec+=15;
    pthread_mutex_lock(&d->mutex);
    while(!d->finished) {
        if(pthread_cond_timedwait(&d->condition,&d->mutex,&until)) {
            if(!d->finished) hsc_interrupt_cancel(d->interrupt);
            break;
        }
    }
    pthread_mutex_unlock(&d->mutex);
    return NULL;
}
static unsigned dimension(const char *text, unsigned maximum) {
    char *end = NULL;
    errno = 0;
    unsigned long value = strtoul(text, &end, 10);
    if (errno || !*text || *end || value == 0 || value > maximum) return 0;
    return (unsigned)value;
}
int main(int argc, char **argv) {
    if (argc != 5 && argc != 8) {
        fprintf(stderr, "usage: sessions-observe ENDPOINT FONT_PATH SHELL_COMMAND packed|cached [COLUMNS ROWS FONT_PIXELS]\n");
        return 2;
    }
    unsigned columns = argc == 8 ? dimension(argv[5], 160) : 128;
    unsigned rows = argc == 8 ? dimension(argv[6], 80) : 40;
    unsigned font_pixels = argc == 8 ? dimension(argv[7], 256) : 16;
    if (!columns || !rows || !font_pixels) return 2;
    int cached = strcmp(argv[4], "cached") == 0;
    if (!cached && strcmp(argv[4], "packed")) return 2;
    int result = 1;
    hsc_interrupt *interrupt=NULL;
    struct deadline deadline={.mutex=PTHREAD_MUTEX_INITIALIZER};
    pthread_condattr_t attributes;
    if(pthread_condattr_init(&attributes)) return 1;
    if(pthread_condattr_setclock(&attributes,CLOCK_MONOTONIC)) { pthread_condattr_destroy(&attributes); return 1; }
    int condition_status=pthread_cond_init(&deadline.condition,&attributes);
    pthread_condattr_destroy(&attributes);
    if(condition_status) return 1;
    pthread_t timer; int timer_started=0;
    hsc_control *control = NULL;
    hsc_attachment *input = NULL;
    struct observer host = {0};
    uint64_t session = 0;
    size_t endpoint_len = strlen(argv[1]);
    REQUIRE(hsc_control_open(HSC_ABI_VERSION, (const uint8_t *)argv[1], endpoint_len, NULL, &control) == HSC_OK);
    hsc_server_status server = {0};
    REQUIRE(hsc_control_status(control, &server) == HSC_OK);
    const char *name = "slint-workload";
    REQUIRE(hsc_session_create(control, (const uint8_t *)name, strlen(name), &session) == HSC_OK);
    /* Input starts the workload only after fonts and attachment are ready. */
    char command[4096];
    int length = snprintf(command, sizeof(command), "read start; %s", argv[3]);
    REQUIRE(length > 0 && (size_t)length < sizeof(command));
    hsc_launch launch = {.session_id = session, .rows = (uint16_t)rows, .columns = (uint16_t)columns, .history_rows = 32,
        .shell = (const uint8_t *)"/bin/sh", .shell_len = 7,
        .command = (const uint8_t *)command, .command_len = (size_t)length};
    hsc_identity identity = {0};
    REQUIRE(hsc_instance_create(control, &launch, &identity) == HSC_OK);
    REQUIRE(hsc_attachment_open(HSC_ABI_VERSION, (const uint8_t *)argv[1], endpoint_len,
        server.server_id, session, identity.instance_id, NULL, &input) == HSC_OK);
    REQUIRE(hsc_interrupt_create(HSC_ABI_VERSION,&interrupt)==HSC_OK);
    REQUIRE(hsc_attachment_open(HSC_ABI_VERSION, (const uint8_t *)argv[1], endpoint_len,
        server.server_id, session, identity.instance_id, interrupt, &host.attachment) == HSC_OK);
    if (cached) REQUIRE(hsc_cache_create(HSC_ABI_VERSION, host.attachment, &host.cache) == HSC_OK);
    hsr_family_config config = {.pixel_size = (uint16_t)font_pixels};
    for (unsigned i=0; i<4; i++) config.fonts[i].primary = (hsr_bytes){(const uint8_t *)argv[2], strlen(argv[2])};
    REQUIRE(hsr_create_family(HSR_ABI_VERSION, &config, &host.renderer) == HSR_OK);
    hrc_cell_size cell = {0};
    REQUIRE(hsr_cell_size(host.renderer, &cell) == HSR_OK);
    uint16_t cell_width = cell.width, cell_height = cell.height;
    hsc_geometry geometry = {(uint16_t)rows, (uint16_t)columns, cell_width, cell_height};
    REQUIRE(hsc_resize_geometry(input, &geometry, 1) == HSC_OK);
    int exited = 0;
    REQUIRE(observe_step(&host, &exited) == HSC_OK);
    double wall0 = milliseconds(CLOCK_MONOTONIC), cpu0 = milliseconds(CLOCK_PROCESS_CPUTIME_ID);
    REQUIRE(hsc_named_key(input, HSC_KEY_ENTER, HSC_KEY_PRESS, 0) == HSC_OK);
    deadline.interrupt=interrupt;
    REQUIRE(pthread_create(&timer,NULL,deadline_run,&deadline)==0); timer_started=1;
    unsigned frames = 0;
    /* Store bounded samples; print only after measurement so stdout does not
     * become part of the frame path. These are observations, not presentations. */
    struct sample { double elapsed, wall, cpu, observe_wall, observe_cpu, capture_cpu, paint_cpu; } samples[4096];
    while (!exited && milliseconds(CLOCK_MONOTONIC) - wall0 < 15000) {
        REQUIRE(frames < sizeof(samples) / sizeof(samples[0]));
        double step_wall = milliseconds(CLOCK_MONOTONIC);
        double step_cpu = milliseconds(CLOCK_THREAD_CPUTIME_ID);
        REQUIRE(observe_step(&host, &exited) == HSC_OK);
        REQUIRE(host.surface.pixels && host.surface.width && host.surface.height);
        double end = milliseconds(CLOCK_MONOTONIC);
        samples[frames++] = (struct sample){end - wall0, end - step_wall,
            milliseconds(CLOCK_THREAD_CPUTIME_ID) - step_cpu, host.observe_wall, host.observe_cpu, host.capture_cpu, host.paint_cpu};
    }
    REQUIRE(exited);
    double cpu = milliseconds(CLOCK_PROCESS_CPUTIME_ID) - cpu0, wall = milliseconds(CLOCK_MONOTONIC) - wall0;
    printf("WORKLOAD_BENCH frames=%u width=%u height=%u wall_ms=%.3f client_cpu_ms=%.3f step_wall_ms=%.3f\n", frames, host.surface.width, host.surface.height, wall, cpu, wall / frames);
    printf("OBSERVATION_MODE %s\n", argv[4]);
    printf("WORKLOAD_GEOMETRY columns=%u rows=%u font_pixels=%u cell_width=%u cell_height=%u\n",
        columns, rows, font_pixels, cell_width, cell_height);
    for (unsigned i = 0; i < frames; i++)
        printf("WORKLOAD_SAMPLE index=%u elapsed_ms=%.3f wall_ms=%.3f cpu_ms=%.3f observe_wall_ms=%.3f observe_cpu_ms=%.3f capture_cpu_ms=%.3f paint_cpu_ms=%.3f\n",
            i, samples[i].elapsed, samples[i].wall, samples[i].cpu, samples[i].observe_wall, samples[i].observe_cpu, samples[i].capture_cpu, samples[i].paint_cpu);
    REQUIRE(parity(host.attachment,input,argv[2],(uint16_t)font_pixels)==0);
    printf("OBSERVATION_PARITY cells_scalars=equal immutable_after_cache_release=pass foreign_attachment=refused\n");
    hsc_interrupt_cancel(interrupt);
    hsc_snapshot *cancelled=NULL;
    uint32_t cancelled_status = cached ? hsc_observe_cached(host.attachment,host.cache,0,0,&cancelled)
                                      : hsc_observe(host.attachment,0,0,&cancelled);
    REQUIRE(cancelled_status==HSC_CANCELLED && !cancelled);
    printf("OBSERVATION_CANCEL cancelled=1 fresh_attachment_cache=pass\n");
    result = 0;
done:
    if(timer_started) {
        pthread_mutex_lock(&deadline.mutex); deadline.finished=1;
        pthread_cond_signal(&deadline.condition); pthread_mutex_unlock(&deadline.mutex);
        pthread_join(timer,NULL);
    }
    pthread_cond_destroy(&deadline.condition); pthread_mutex_destroy(&deadline.mutex);
    hsc_cache_release(&host.cache);
    hsc_attachment_release(&host.attachment);
    if (hsr_try_destroy(&host.renderer) != HSR_OK) result = 1;
    free(host.surface.pixels);
    hsc_interrupt_release(&interrupt);
    hsc_attachment_release(&input);
    if (session && hsc_session_close(control, session) != HSC_OK) result = 1;
    hsc_control_release(&control);
    return result;
}
