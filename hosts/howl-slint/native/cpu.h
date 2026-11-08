#ifndef HOWL_SLINT_CPU_H
#define HOWL_SLINT_CPU_H
#include "howl_render_native.h"
#define CPU_MAX_SIDE 4096u
#define CPU_MAX_PIXELS (16u * 1024u * 1024u)
/* Host CPU surface, not a new public Howl ABI. Caller owns pixel storage. */
struct cpu_surface { uint8_t *pixels; uint32_t width, height; };
uint32_t cpu_paint(struct cpu_surface *, const hrc_frame_info *, const hrc_command *, const hrc_upload *);
#endif
