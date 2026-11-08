#define _POSIX_C_SOURCE 200809L
#include "howl_instance_native.h"
#include <errno.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Disposable CPU presentation proof. Howl owns PTY/VT/shaping; this adapter
 * only composites its canonical rectangles. No atlas cache: release reports
 * zero residency so each frame is independently complete. One worker owns all
 * calls. */
#define MAX_COMMANDS 32768u
#define MAX_UPLOADS 16u
#define MAX_SIDE 2048u
struct proof_terminal {
  hi_instance *instance;
  hi_frame_stream *stream;
  hi_cell_size cell;
  hrc_command *commands;
  uint8_t *pixels;
  uint32_t width, height;
  int dirty, exited;
};
static uint64_t now_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}
static hi_bytes bytes(const char *s) {
  return (hi_bytes){(const uint8_t *)s, strlen(s)};
}
uint32_t proof_close(struct proof_terminal *p) {
  if (!p)
    return HI_OK;
  hi_frame_close(&p->stream);
  uint32_t status = hi_destroy(&p->instance);
  if (status != HI_OK)
    return status;
  free(p->commands);
  free(p->pixels);
  free(p);
  return HI_OK;
}
uint32_t proof_open(const char *const *fonts, const char *const *fallbacks,
                    size_t fallback_count, const char *home,
                    uint16_t pixel_size, struct proof_terminal **out) {
  if (fallback_count > HI_MAX_FONT_FALLBACKS)
    return HI_RESOURCE_LIMIT;
  struct proof_terminal *p = calloc(1, sizeof(*p));
  if (!p)
    return HI_OUT_OF_MEMORY;
  hi_presentation *presentation = NULL;
  uint32_t status = HI_OUT_OF_MEMORY;
  p->commands = calloc(MAX_COMMANDS, sizeof(*p->commands));
  p->pixels = malloc(MAX_SIDE * MAX_SIDE * 4u);
  if (!p->commands || !p->pixels)
    goto fail;
  hi_presentation_config sc = {0};
  sc.pixel_size = pixel_size;
  sc.max_sequence_scalars = 64;
  sc.shape_entries = 4096;
  sc.shape_scalars = 16384;
  sc.shape_glyphs = 16384;
  sc.shaped_capacity = 4096;
  sc.raster_bytes = 1024 * 1024;
  hi_bytes fallback_bytes[HI_MAX_FONT_FALLBACKS];
  for (size_t i = 0; i < fallback_count; i++)
    fallback_bytes[i] = bytes(fallbacks[i]);
  for (size_t i = 0; i < 4; i++) {
    if (!fonts[i])
      continue; // An explicitly absent style uses Howl's native policy.
    sc.fonts[i].kind = HI_FONT_PATH;
    sc.fonts[i].primary = bytes(fonts[i]);
    sc.fonts[i].fallbacks = fallback_bytes;
    sc.fonts[i].fallback_count = fallback_count;
  }
  status = hi_presentation_create(HI_ABI_VERSION, &sc, &presentation);
  if (status)
    goto fail;
  status = hi_presentation_cell_size(presentation, &p->cell);
  if (status)
    goto fail;
  hi_presented_config pc = {0};
  pc.stroke_points[0] = 0.001f;
  pc.stroke_points[1] = 1;
  pc.stroke_points[2] = 1.5f;
  pc.stroke_points[3] = 2;
  pc.dpi_x_numerator = pc.dpi_y_numerator = 96;
  pc.dpi_x_denominator = pc.dpi_y_denominator = 1;
  pc.atlas_width = pc.atlas_height = 1024;
  pc.atlas_gap = 1;
  pc.atlas_entries = 4096;
  pc.command_capacity = 4096;
  pc.command_limit = MAX_COMMANDS;
  char *home_env = malloc(strlen(home) + 6);
  if (!home_env) {
    status = HI_OUT_OF_MEMORY;
    goto fail;
  }
  strcpy(home_env, "HOME=");
  strcat(home_env, home);
  hi_bytes env[] = {bytes("PATH=/usr/local/bin:/usr/bin:/bin"), bytes(home_env),
                    bytes("LANG=C.UTF-8"), bytes("TERM=xterm-256color"),
                    bytes("COLORTERM=truecolor")};
  hi_launch launch = {0};
  launch.shell = bytes("/bin/sh");
  launch.command = bytes("exec /bin/bash --noprofile --norc -i");
  launch.cwd = bytes(home);
  launch.environment = env;
  launch.environment_count = sizeof(env) / sizeof(env[0]);
  launch.rows = 24;
  launch.columns = 80;
  launch.history_rows = 256;
  status = hi_create_presented(HI_ABI_VERSION, &launch, presentation, &pc,
                               &p->instance);
  free(home_env);
  if (status)
    goto fail;
  status = hi_frame_open(HI_ABI_VERSION, p->instance, &p->stream);
  if (status)
    goto fail;
  hi_presentation_release(&presentation);
  p->dirty = 1;
  *out = p;
  return HI_OK;
fail:
  hi_presentation_release(&presentation);
  proof_close(p);
  return status;
}
uint32_t proof_key(struct proof_terminal *p, uint8_t key, uint32_t scalar,
                   uint8_t action, uint8_t mods) {
  p->dirty = 1;
  return key ? hi_send_named_key(p->instance, key, action, mods)
             : hi_send_unicode_key(p->instance, scalar, action, mods);
}
uint32_t proof_resize(struct proof_terminal *p, uint32_t width,
                      uint32_t height) {
  if (width < p->cell.width || height < p->cell.height)
    return HI_OK;
  uint32_t columns = width / p->cell.width,
           rows = height / p->cell.height;
  if (columns > 160)
    columns = 160;
  if (rows > 80)
    rows = 80;
  if ((uint32_t)columns * p->cell.width > MAX_SIDE ||
      (uint32_t)rows * p->cell.height > MAX_SIDE)
    return HI_RESOURCE_LIMIT;
  p->dirty = 1;
  return hi_resize(p->instance, (uint16_t)rows, (uint16_t)columns, 0, 0);
}
/* Straight-alpha source-over onto an opaque destination. Canonical RGBA is
 * low-to-high R,G,B,A; alpha-mask commands tint their coverage with that color.
 */
static void blend(uint8_t *d, uint32_t rgba, unsigned coverage) {
  unsigned a = (rgba >> 24) * coverage / 255u;
  for (unsigned n = 0; n < 3; n++)
    d[n] = (uint8_t)((((rgba >> (8 * n)) & 255u) * a + d[n] * (255 - a) + 127) /
                     255);
  d[3] = 255;
}
static uint32_t paint(struct proof_terminal *p, const hi_frame_info *f,
                      const hrc_upload *uploads) {
  if (!f->surface_width || !f->surface_height || f->surface_width > MAX_SIDE ||
      f->surface_height > MAX_SIDE)
    return HI_RESOURCE_LIMIT;
  p->width = f->surface_width;
  p->height = f->surface_height;
  for (size_t n = 0; n < (size_t)p->width * p->height; n++) {
    uint8_t *d = p->pixels + n * 4;
    for (unsigned k = 0; k < 3; k++)
      d[k] = (uint8_t)(f->background_rgba >> (8 * k));
    d[3] = 255;
  }
  for (uint32_t n = 0; n < f->command_count; n++) {
    const hrc_command *c = &p->commands[n];
    const hrc_upload *u = NULL;
    if (c->tag != HRC_SOLID) {
      for (uint32_t k = 0; k < f->upload_count; k++)
        if (uploads[k].info.resource == c->resource &&
            uploads[k].info.generation == c->generation)
          u = &uploads[k];
      if (!u || !c->destination_width || !c->destination_height ||
          !c->source_width || !c->source_height)
        return HI_INVALID_ARGUMENT;
    }
    int x0 = c->destination_x > c->clip_x ? c->destination_x : c->clip_x;
    int y0 = c->destination_y > c->clip_y ? c->destination_y : c->clip_y;
    int x1 = c->destination_x + c->destination_width,
        y1 = c->destination_y + c->destination_height;
    if (x1 > c->clip_x + c->clip_width)
      x1 = c->clip_x + c->clip_width;
    if (y1 > c->clip_y + c->clip_height)
      y1 = c->clip_y + c->clip_height;
    if (x0 < 0)
      x0 = 0;
    if (y0 < 0)
      y0 = 0;
    if (x1 > (int)p->width)
      x1 = p->width;
    if (y1 > (int)p->height)
      y1 = p->height;
    for (int y = y0; y < y1; y++)
      for (int x = x0; x < x1; x++) {
        uint32_t color = c->color_rgba;
        unsigned alpha = 255;
        if (u) {
          uint32_t sx = c->source_x + (uint32_t)(x - c->destination_x) *
                                          c->source_width /
                                          c->destination_width;
          uint32_t sy = c->source_y + (uint32_t)(y - c->destination_y) *
                                          c->source_height /
                                          c->destination_height;
          unsigned bpp = u->info.format == HRC_ALPHA8 ? 1 : 4;
          size_t offset = (size_t)sy * u->info.stride + (size_t)sx * bpp;
          if (sx >= u->info.width || sy >= u->info.height ||
              offset + bpp > u->pixel_len)
            return HI_INVALID_ARGUMENT;
          if (c->tag == HRC_ALPHA_MASK && bpp == 1)
            alpha = u->pixels[offset];
          else if (c->tag == HRC_RGBA && bpp == 4) {
            const uint8_t *s = u->pixels + offset;
            color = (uint32_t)s[0] | (uint32_t)s[1] << 8 |
                    (uint32_t)s[2] << 16 | (uint32_t)s[3] << 24;
          } else
            return HI_UNSUPPORTED;
        }
        blend(p->pixels + ((size_t)y * p->width + x) * 4, color, alpha);
      }
  }
  return HI_OK;
}
uint32_t proof_step(struct proof_terminal *p, const uint8_t **pixels,
                    uint32_t *width, uint32_t *height, int *exited) {
  *pixels = NULL;
  *exited = p->exited;
  hi_service s;
  uint32_t status = hi_service_turn(p->instance, 0, 0, now_ns(), &s);
  if (status)
    return status;
  p->dirty |= s.changed || s.viewport_changed;
  struct pollfd fd = {s.descriptor,
                      POLLIN | POLLHUP | (s.write_pending ? POLLOUT : 0), 0};
  int wait = s.buffered_output_pending ? 0 : 16;
  if (s.animation_wait_present && s.animation_wait_ms < (uint32_t)wait)
    wait = s.animation_wait_ms;
  if (poll(&fd, 1, wait) < 0 && errno != EINTR)
    return HI_OPERATION_FAILED;
  if (fd.revents & (POLLNVAL | POLLERR))
    return HI_OPERATION_FAILED;
  status = hi_service_turn(p->instance, (fd.revents & (POLLIN | POLLHUP)) != 0,
                           (fd.revents & POLLOUT) != 0, now_ns(), &s);
  if (status)
    return status;
  p->dirty |= s.changed || s.viewport_changed;
  p->exited = s.exit_kind != 0;
  *exited = p->exited;
  if (!p->dirty)
    return HI_OK;
  status = hi_publish_frame(p->instance, 0);
  if (status)
    return status;
  hi_frame_info f;
  status = hi_frame_acquire(p->stream, &f);
  if (status == HI_NO_FRAME)
    return HI_OK;
  if (status)
    return status;
  if (f.command_count > MAX_COMMANDS || f.upload_count > MAX_UPLOADS) {
    hi_frame_abandon(p->stream);
    return HI_RESOURCE_LIMIT;
  }
  hrc_upload uploads[MAX_UPLOADS];
  status = hi_frame_commands(p->stream, p->commands, MAX_COMMANDS);
  if (!status)
    status = hi_frame_uploads(p->stream, uploads, f.upload_count);
  if (!status)
    status = paint(p, &f, uploads);
  uint32_t released = hi_frame_release(p->stream, NULL, 0);
  if (status)
    return status;
  if (released)
    return released;
  p->dirty = 0;
  *pixels = p->pixels;
  *width = p->width;
  *height = p->height;
  return HI_OK;
}
