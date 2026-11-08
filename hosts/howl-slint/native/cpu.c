#include "cpu.h"

/* Straight-alpha source-over onto an opaque destination. Canonical RGBA is
 * low-to-high R,G,B,A; alpha-mask commands tint their coverage with that color.
 */
static void blend(uint8_t *d, uint32_t rgba, unsigned coverage) {
  unsigned a = (rgba >> 24) * coverage / 255u;
  if (a == 0) return; /* The surface is already opaque. */
  if (a == 255) {
    for (unsigned n = 0; n < 3; n++)
      d[n] = (uint8_t)(rgba >> (8 * n));
    return;
  }
  for (unsigned n = 0; n < 3; n++)
    d[n] = (uint8_t)((((rgba >> (8 * n)) & 255u) * a + d[n] * (255 - a) + 127) /
                     255);
  d[3] = 255;
}
uint32_t cpu_paint(struct cpu_surface *p, const hrc_frame_info *f,
                   const hrc_command *commands, const hrc_upload *uploads) {
  if (!f->surface_width || !f->surface_height || f->surface_width > CPU_MAX_SIDE ||
      f->surface_height > CPU_MAX_SIDE ||
      (size_t)f->surface_width * f->surface_height > CPU_MAX_PIXELS)
    return 1;
  p->width = f->surface_width;
  p->height = f->surface_height;
  for (size_t n = 0; n < (size_t)p->width * p->height; n++) {
    uint8_t *d = p->pixels + n * 4;
    for (unsigned k = 0; k < 3; k++)
      d[k] = (uint8_t)(f->background_rgba >> (8 * k));
    d[3] = 255;
  }
  for (uint32_t n = 0; n < f->command_count; n++) {
    const hrc_command *c = &commands[n];
    const hrc_upload *u = NULL;
    if (c->tag != HRC_SOLID) {
      for (uint32_t k = 0; k < f->upload_count; k++)
        if (uploads[k].info.resource == c->resource &&
            uploads[k].info.generation == c->generation)
          u = &uploads[k];
      if (!u || !c->destination_width || !c->destination_height ||
          !c->source_width || !c->source_height)
        return 1;
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
    /* Solid backgrounds dominate terminal area. Resolve alpha once, not
     * once per pixel. Keep resource validation on the textured path below. */
    if (c->tag == HRC_SOLID && (c->color_rgba >> 24) == 0)
      continue;
    if (c->tag == HRC_SOLID && (c->color_rgba >> 24) == 255) {
      uint8_t r = (uint8_t)c->color_rgba;
      uint8_t g = (uint8_t)(c->color_rgba >> 8);
      uint8_t b = (uint8_t)(c->color_rgba >> 16);
      for (int y = y0; y < y1; y++)
        for (int x = x0; x < x1; x++) {
          uint8_t *d = p->pixels + ((size_t)y * p->width + x) * 4;
          d[0] = r; d[1] = g; d[2] = b; d[3] = 255;
        }
      continue;
    }
    /* Glyph masks normally map atlas pixels 1:1. Validate the clipped span
     * once, then advance pointers instead of dividing for every pixel.
     * Invalid spans keep the general path's checked failure behavior. */
    if (u && c->tag == HRC_ALPHA_MASK && u->info.format == HRC_ALPHA8 &&
        c->source_width == c->destination_width &&
        c->source_height == c->destination_height && x0 < x1 && y0 < y1) {
      uint64_t sx = (uint64_t)c->source_x + (uint32_t)(x0 - c->destination_x);
      uint64_t sy = (uint64_t)c->source_y + (uint32_t)(y0 - c->destination_y);
      size_t width = (size_t)(x1 - x0), height = (size_t)(y1 - y0);
      if (sx + width <= u->info.width && sy + height <= u->info.height &&
          (sy + height - 1) * u->info.stride + sx + width <= u->pixel_len) {
        for (size_t row = 0; row < height; row++) {
          const uint8_t *source = u->pixels + (sy + row) * u->info.stride + sx;
          uint8_t *destination = p->pixels + (((size_t)y0 + row) * p->width + x0) * 4;
          for (size_t column = 0; column < width; column++)
            blend(destination + column * 4, c->color_rgba, source[column]);
        }
        continue;
      }
    }
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
            return 1;
          if (c->tag == HRC_ALPHA_MASK && bpp == 1)
            alpha = u->pixels[offset];
          else if (c->tag == HRC_RGBA && bpp == 4) {
            const uint8_t *s = u->pixels + offset;
            color = (uint32_t)s[0] | (uint32_t)s[1] << 8 |
                    (uint32_t)s[2] << 16 | (uint32_t)s[3] << 24;
          } else
            return 1;
        }
        blend(p->pixels + ((size_t)y * p->width + x) * 4, color, alpha);
      }
  }
  return 0;
}
