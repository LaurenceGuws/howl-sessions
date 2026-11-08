#ifndef HOWL_SLINT_REMOTE_H
#define HOWL_SLINT_REMOTE_H
#include "howl_server_client.h"
/* Private host adapter, not another published terminal ABI. One serial worker
 * owns this client. Interrupt may cancel from another thread, but outlives it.
 * Input strings borrow calls; returned pixels borrow until the next call. */
struct remote_client;
uint32_t remote_open(const char *, hsc_interrupt *, struct remote_client **);
uint32_t remote_close(struct remote_client *);
size_t remote_count(const struct remote_client *);
uint32_t remote_item(const struct remote_client *, size_t, char *, size_t, size_t *, uint64_t *, uint64_t *, uint64_t *);
uint32_t remote_attach(struct remote_client *, uint64_t, uint64_t, uint64_t, const char *const *, const char *const *, size_t, uint16_t);
uint32_t remote_key(struct remote_client *, uint8_t, uint32_t, uint8_t, uint8_t);
uint32_t remote_resize(struct remote_client *, uint32_t, uint32_t);
uint32_t remote_step(struct remote_client *, const uint8_t **, uint32_t *, uint32_t *, int *);
#endif
