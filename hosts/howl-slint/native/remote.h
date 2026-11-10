#ifndef HOWL_SLINT_REMOTE_H
#define HOWL_SLINT_REMOTE_H
#include "howl_server_client.h"
#include "howl_render_native.h"
/* Private host adapter, not another published terminal ABI. One serial worker
 * owns this client. Interrupt may cancel from another thread, but outlives it.
 * Input strings borrow calls; returned pixels borrow until the next call. */
struct remote_client;
uint32_t remote_open(const char *, hsc_interrupt *, struct remote_client **);
uint32_t remote_close(struct remote_client *);
size_t remote_count(const struct remote_client *);
uint32_t remote_item(const struct remote_client *, size_t, char *, size_t, size_t *, uint64_t *, uint64_t *, uint64_t *);
uint32_t remote_attach(struct remote_client *, uint64_t, uint64_t, uint64_t, const char *const *, const char *const *, size_t, uint16_t);
uint32_t remote_cell_size(const struct remote_client *, uint16_t *, uint16_t *);
/* A separate serial owner serves actions while observation sleeps. Its interrupt
 * must be distinct from the observer's; both are borrowed until close. */
struct remote_actions;
uint32_t remote_actions_open(const char *, hsc_interrupt *, uint64_t, uint64_t, uint64_t, struct remote_actions **);
void remote_actions_close(struct remote_actions *);
uint32_t remote_actions_key(struct remote_actions *, uint8_t, uint32_t, uint8_t, uint8_t);
uint32_t remote_actions_resize(struct remote_actions *, uint32_t, uint32_t, uint16_t, uint16_t);
/* Runs synchronously on the serial client owner. The canonical view and all
 * referenced pixels borrow only this callback; copy before returning if another
 * thread will consume them. Return HSC_OK only after taking ownership. Failure
 * releases frame/snapshot, discards the Client baseline and resets revision zero,
 * returning the original error without an I/O retry. A later explicit call can
 * resync only on a still-usable stream; malformed/partial I/O retires it. Invalid
 * arguments rejected before a step leave the prior acknowledgement intact.
 * Observation requires a Server supporting request64/raw-full58/delta65; SRVR2
 * alone is not a capability guarantee. Never unwind
 * through this C callback or re-enter the client from it. Residency names actual
 * caller-owned immutable pixels; a dropped presentation is not residency loss. */
typedef uint32_t (*remote_frame_consumer)(void *, const hrc_frame_view *);
uint32_t remote_visit(struct remote_client *, const hrc_residency *, size_t, remote_frame_consumer, void *, int *);
uint32_t remote_step(struct remote_client *, const uint8_t **, uint32_t *, uint32_t *, int *);
#endif
