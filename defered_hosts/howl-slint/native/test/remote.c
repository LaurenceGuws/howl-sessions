/* Host-owner failure/lifetime tests. Test doubles replace only the published
 * Client/Render calls on this path; live sessions.c covers real transport. No
 * production fault-injection API or transport implementation is added here. */
#include "../remote.c"
#include <stdio.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "remote test line %d: %s\n", __LINE__, #x); abort(); } } while (0)
static int attachment_token, cache_token, snapshot_token, renderer_token, frame_token;
#define TOKEN(type, name) ((type *)(void *)&name##_token)
static uint32_t create_error, observe_error, metadata_error, capture_error, read_error, consume_error;
static uint32_t renderer_error, cell_error, attach_error;
static unsigned creates, observations, consumes, cache_live, snapshot_live, frame_live;
static uint64_t after, delivery = 11;
static char releases[32];
static size_t release_count;
static void released(char c) { CHECK(release_count + 1 < sizeof(releases)); releases[release_count++] = c; }

uint32_t hsc_cache_create(uint32_t version, hsc_attachment *attachment, hsc_cache **out) {
    CHECK(version == HSC_ABI_VERSION && attachment == TOKEN(hsc_attachment, attachment) && !*out && !cache_live);
    creates++;
    if (create_error) return create_error;
    *out = TOKEN(hsc_cache, cache); cache_live = 1; return HSC_OK;
}
void hsc_cache_release(hsc_cache **owner) {
    if (!*owner) return;
    CHECK(*owner == TOKEN(hsc_cache, cache) && cache_live && !snapshot_live && !frame_live);
    released('C'); *owner = NULL; cache_live = 0;
}
uint32_t hsc_observe_cached_compressed(hsc_attachment *attachment, hsc_cache *cache, uint64_t revision, uint32_t history, hsc_snapshot **out) {
    CHECK(attachment == TOKEN(hsc_attachment, attachment) && cache == TOKEN(hsc_cache, cache) && cache_live && !*out && !history);
    observations++; after = revision;
    if (observe_error) return observe_error;
    CHECK(!snapshot_live); *out = TOKEN(hsc_snapshot, snapshot); snapshot_live = 1; return HSC_OK;
}
uint32_t hsc_snapshot_metadata(const hsc_snapshot *snapshot, hsc_metadata *out) {
    CHECK(snapshot == TOKEN(hsc_snapshot, snapshot) && snapshot_live);
    if (metadata_error) return metadata_error;
    *out = (hsc_metadata){.delivery_revision = delivery}; return HSC_OK;
}
uint32_t hsr_capture(hsr_renderer *renderer, const hsc_snapshot *snapshot, const hrc_residency *residency, size_t count, hsr_frame **out) {
    CHECK(renderer == TOKEN(hsr_renderer, renderer) && snapshot == TOKEN(hsc_snapshot, snapshot) && snapshot_live && !*out && !frame_live && !residency && !count);
    if (capture_error) return capture_error;
    *out = TOKEN(hsr_frame, frame); frame_live = 1; return HSR_OK;
}
uint32_t hsr_frame_read(const hsr_frame *frame, hrc_frame_view *out) {
    CHECK(frame == TOKEN(hsr_frame, frame) && frame_live && snapshot_live);
    if (read_error) return read_error;
    *out = (hrc_frame_view){0}; return HSR_OK;
}
void hsr_frame_release(hsr_frame **owner) {
    if (!*owner) return;
    CHECK(*owner == TOKEN(hsr_frame, frame) && frame_live && snapshot_live);
    released('F'); *owner = NULL; frame_live = 0;
}
void hsc_snapshot_release(hsc_snapshot **owner) {
    if (!*owner) return;
    CHECK(*owner == TOKEN(hsc_snapshot, snapshot) && snapshot_live && !frame_live);
    released('S'); *owner = NULL; snapshot_live = 0;
}
void hsc_attachment_release(hsc_attachment **owner) {
    if (!*owner) return;
    CHECK(*owner == TOKEN(hsc_attachment, attachment) && !cache_live && !snapshot_live && !frame_live);
    released('A'); *owner = NULL;
}
uint32_t hsr_try_destroy(hsr_renderer **owner) {
    CHECK(!frame_live);
    if (*owner) { CHECK(*owner == TOKEN(hsr_renderer, renderer)); released('R'); *owner = NULL; }
    return HSR_OK;
}
uint32_t hsr_create_family(uint32_t version, const hsr_family_config *config, hsr_renderer **out) {
    CHECK(version == HSR_ABI_VERSION && config->fonts[0].primary.len && !*out);
    if (renderer_error) return renderer_error;
    *out = TOKEN(hsr_renderer, renderer); return HSR_OK;
}
uint32_t hsr_cell_size(const hsr_renderer *renderer, hrc_cell_size *out) {
    CHECK(renderer == TOKEN(hsr_renderer, renderer));
    if (cell_error) return cell_error;
    *out = (hrc_cell_size){.width = 8, .height = 20}; return HSR_OK;
}
uint32_t hsc_attachment_open(uint32_t version, const uint8_t *endpoint, size_t length, uint64_t server, uint64_t session, uint64_t instance, hsc_interrupt *interrupt, hsc_attachment **out) {
    (void)endpoint; (void)server; (void)session; (void)instance; (void)interrupt;
    CHECK(version == HSC_ABI_VERSION && length && !*out && !cache_live);
    if (attach_error) return attach_error;
    *out = TOKEN(hsc_attachment, attachment); return HSC_OK;
}
static uint32_t consume(void *context, const hrc_frame_view *view) {
    (void)context; CHECK(view && frame_live && snapshot_live && cache_live); consumes++; return consume_error;
}
static uint32_t visit(struct remote_client *p) {
    int exited = 99; uint32_t status = remote_visit(p, NULL, 0, consume, NULL, &exited);
    CHECK(exited == 0 && !snapshot_live && !frame_live); return status;
}
static void clear_releases(void) { memset(releases, 0, sizeof(releases)); release_count = 0; }
static void expect_releases(const char *expected) { CHECK(strcmp(releases, expected) == 0); clear_releases(); }
int main(void) {
    struct remote_client *p = calloc(1, sizeof(*p)); CHECK(p);
    p->endpoint = strdup("unix:fixture"); CHECK(p->endpoint);
    p->attachment = TOKEN(hsc_attachment, attachment); p->renderer = TOKEN(hsr_renderer, renderer);
    /* Lazy-constructor OOM has no I/O, cache or acknowledgement. */
    create_error = HSC_OUT_OF_MEMORY;
    CHECK(visit(p) == HSC_OUT_OF_MEMORY && !observations && !p->cache && !p->revision);
    create_error = 0;
    CHECK(visit(p) == HSC_OK && after == 0 && p->revision == delivery && creates == 2);
    expect_releases("FS");
    /* Prevalidation cannot corrupt an accepted predecessor or discard cache. */
    int exited = 77; unsigned prior = observations;
    CHECK(remote_visit(p, NULL, 0, NULL, NULL, &exited) == HSC_INVALID_ARGUMENT);
    CHECK(remote_visit(p, NULL, 1, consume, NULL, &exited) == HSC_INVALID_ARGUMENT);
    CHECK(remote_attach(p, 1, 2, 3, NULL, NULL, 0, 16) == HSC_INVALID_ARGUMENT);
    CHECK(exited == 77 && observations == prior && p->cache && p->revision == delivery);
    CHECK(visit(p) == HSC_OK && after == delivery && creates == 2); expect_releases("FS");
    /* Three rejected consumes, each one attempt, followed by same-handle reuse. */
    consume_error = HSC_RESOURCE_LIMIT;
    for (unsigned i = 0; i < 3; i++) {
        prior = observations;
        CHECK(visit(p) == HSC_RESOURCE_LIMIT && observations == prior + 1 && !p->cache && !p->revision);
        expect_releases("FSC");
    }
    consume_error = 0;
    CHECK(visit(p) == HSC_OK && after == 0); expect_releases("FS");
    /* Original Client/Render statuses survive; no hidden observation retry. */
    uint32_t client_errors[] = {HSC_OUT_OF_MEMORY, HSC_CANCELLED, HSC_PROTOCOL_ERROR, HSC_UNAVAILABLE, HSC_INVALID_ARGUMENT};
    for (size_t i = 0; i < sizeof(client_errors)/sizeof(client_errors[0]); i++) {
        observe_error = client_errors[i]; prior = observations;
        CHECK(visit(p) == observe_error && observations == prior + 1 && !p->cache && !p->revision); expect_releases("C");
        observe_error = 0; CHECK(visit(p) == HSC_OK && after == 0); expect_releases("FS");
    }
    metadata_error = HSC_INVALID_ARGUMENT;
    CHECK(visit(p) == metadata_error && !p->cache && !p->revision); expect_releases("SC");
    metadata_error = 0; CHECK(visit(p) == HSC_OK && after == 0); expect_releases("FS");
    capture_error = HSR_OUT_OF_MEMORY;
    CHECK(visit(p) == 100 + capture_error && !p->cache && !p->revision); expect_releases("SC");
    capture_error = 0; CHECK(visit(p) == HSC_OK && after == 0); expect_releases("FS");
    read_error = HSR_RENDER_FAILED;
    CHECK(visit(p) == 100 + read_error && !p->cache && !p->revision); expect_releases("FSC");
    read_error = 0; CHECK(visit(p) == HSC_OK && after == 0); expect_releases("FS");
    /* Replacement revokes the exact old attachment/cache even on partial setup.
     * A renderer created before cell/attachment failure remains owned to close. */
    const char *fonts[] = {"fixture", NULL, NULL, NULL};
    uint32_t *errors[] = {&renderer_error, &cell_error, &attach_error};
    for (unsigned i = 0; i < 3; i++) {
        *errors[i] = i == 2 ? HSC_UNAVAILABLE : HSR_OUT_OF_MEMORY;
        CHECK(remote_attach(p, 1, 2, 3, fonts, NULL, 0, 16) == (i == 2 ? *errors[i] : 100 + *errors[i]));
        CHECK(!p->cache && !p->attachment && !p->revision); expect_releases("CAR");
        prior = observations; CHECK(visit(p) == HSC_UNAVAILABLE && observations == prior);
        *errors[i] = 0;
        CHECK(remote_attach(p, 4, 5, 6, fonts, NULL, 0, 16) == HSC_OK);
        expect_releases(i == 0 ? "" : "R");
        CHECK(visit(p) == HSC_OK && after == 0); expect_releases("FS");
    }
    CHECK(remote_attach(p, 7, 8, 9, fonts, NULL, 0, 20) == HSC_OK); expect_releases("CAR");
    CHECK(!p->cache && !p->revision && visit(p) == HSC_OK && after == 0); expect_releases("FS");
    CHECK(remote_close(p) == HSC_OK); expect_releases("CAR");
    CHECK(!cache_live && !snapshot_live && !frame_live && consumes);
    puts("REMOTE_OWNER_TESTS_PASSED");
}
