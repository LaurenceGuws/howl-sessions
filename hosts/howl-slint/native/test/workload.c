/* Run a caller-selected finite workload in a disposable Server Session.
 * Measures native snapshot/capture/composition, not Slint or displayed FPS. */
#define _POSIX_C_SOURCE 200809L
#include "howl_server_client.h"
#include "remote.h"
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <pthread.h>
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "workload line %d: %s\n", __LINE__, #x); goto done; } } while (0)
static double milliseconds(clockid_t clock) {
    struct timespec now; clock_gettime(clock, &now);
    return now.tv_sec * 1000.0 + now.tv_nsec / 1000000.0;
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
int main(int argc, char **argv) {
    if (argc != 4) { fprintf(stderr, "usage: sessions-workload ENDPOINT FONT_PATH SHELL_COMMAND\n"); return 2; }
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
    struct remote_client *host = NULL;
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
    hsc_launch launch = {.session_id = session, .rows = 40, .columns = 128, .history_rows = 32,
        .shell = (const uint8_t *)"/bin/sh", .shell_len = 7,
        .command = (const uint8_t *)command, .command_len = (size_t)length};
    hsc_identity identity = {0};
    REQUIRE(hsc_instance_create(control, &launch, &identity) == HSC_OK);
    REQUIRE(hsc_attachment_open(HSC_ABI_VERSION, (const uint8_t *)argv[1], endpoint_len,
        server.server_id, session, identity.instance_id, NULL, &input) == HSC_OK);
    REQUIRE(hsc_interrupt_create(HSC_ABI_VERSION,&interrupt)==HSC_OK);
    REQUIRE(remote_open(argv[1], interrupt, &host) == HSC_OK);
    const char *fonts[] = {argv[2], argv[2], argv[2], argv[2]};
    REQUIRE(remote_attach(host, server.server_id, session, identity.instance_id, fonts, NULL, 0, 16) == HSC_OK);
    const uint8_t *pixels; uint32_t width = 0, height = 0; int exited = 0;
    REQUIRE(remote_step(host, &pixels, &width, &height, &exited) == HSC_OK);
    double wall0 = milliseconds(CLOCK_MONOTONIC), cpu0 = milliseconds(CLOCK_PROCESS_CPUTIME_ID);
    REQUIRE(hsc_named_key(input, HSC_KEY_ENTER, HSC_KEY_PRESS, 0) == HSC_OK);
    deadline.interrupt=interrupt;
    REQUIRE(pthread_create(&timer,NULL,deadline_run,&deadline)==0); timer_started=1;
    unsigned frames = 0;
    while (!exited && milliseconds(CLOCK_MONOTONIC) - wall0 < 15000) {
        REQUIRE(remote_step(host, &pixels, &width, &height, &exited) == HSC_OK);
        REQUIRE(pixels && width && height);
        frames++;
    }
    REQUIRE(exited);
    double cpu = milliseconds(CLOCK_PROCESS_CPUTIME_ID) - cpu0, wall = milliseconds(CLOCK_MONOTONIC) - wall0;
    printf("WORKLOAD_BENCH frames=%u width=%u height=%u wall_ms=%.3f client_cpu_ms=%.3f step_wall_ms=%.3f\n", frames, width, height, wall, cpu, wall / frames);
    result = 0;
done:
    if(timer_started) {
        pthread_mutex_lock(&deadline.mutex); deadline.finished=1;
        pthread_cond_signal(&deadline.condition); pthread_mutex_unlock(&deadline.mutex);
        pthread_join(timer,NULL);
    }
    pthread_cond_destroy(&deadline.condition); pthread_mutex_destroy(&deadline.mutex);
    if (remote_close(host) != HSC_OK) result = 1;
    hsc_interrupt_release(&interrupt);
    hsc_attachment_release(&input);
    if (session && hsc_session_close(control, session) != HSC_OK) result = 1;
    hsc_control_release(&control);
    return result;
}
