#include "cpu.h"
#include <stdio.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "CPU test line %d\n", __LINE__); return 1; } } while (0)
/* Original integer source-over formula, independent of production shortcuts. */
static void reference_blend(uint8_t *d, uint32_t rgba, unsigned coverage) {
    unsigned a = (rgba >> 24) * coverage / 255u;
    for (unsigned n = 0; n < 3; n++)
        d[n] = (uint8_t)((((rgba >> (8 * n)) & 255u) * a +
                         d[n] * (255 - a) + 127) / 255);
    d[3] = 255;
}
static int blend_equivalence(void) {
    uint8_t pixels[24], expected[24], coverage;
    struct cpu_surface surface = {.pixels = pixels};
    hrc_frame_info info = {.surface_width = 3, .surface_height = 2,
        .background_rgba = 0xffa35127, .command_count = 1, .upload_count = 1};
    hrc_upload upload = {.pixels = &coverage, .pixel_len = 1};
    upload.info.resource = upload.info.generation = 1;
    upload.info.width = upload.info.height = upload.info.stride = 1;
    upload.info.format = HRC_ALPHA8;
    hrc_command c = {.resource = 1, .generation = 1,
        .source_width = 1, .source_height = 1,
        .destination_x = -1, .destination_width = 4, .destination_height = 2,
        .clip_x = 1, .clip_width = 3, .clip_height = 1};
    for (unsigned tag = 0; tag < 2; tag++) {
        c.tag = tag ? HRC_ALPHA_MASK : HRC_SOLID;
        for (unsigned a = 0; a < 256; a++) {
            c.color_rgba = (a << 24) | 0x39a7ed;
            for (unsigned mask = 0; mask < 256; mask++) {
                coverage = (uint8_t)mask;
                for (unsigned i = 0; i < 6; i++) {
                    expected[4*i] = 0x27; expected[4*i+1] = 0x51;
                    expected[4*i+2] = 0xa3; expected[4*i+3] = 255;
                }
                reference_blend(expected + 4, c.color_rgba, tag ? mask : 255);
                reference_blend(expected + 8, c.color_rgba, tag ? mask : 255);
                CHECK(cpu_paint(&surface, &info, &c, &upload) == 0);
                CHECK(memcmp(pixels, expected, sizeof pixels) == 0);
            }
        }
    }
    return 0;
}
static int mask_one_to_one(void) {
    uint8_t pixels[48], expected[48], atlas[24];
    for (unsigned i = 0; i < sizeof atlas; i++) atlas[i] = (uint8_t)(i * 37);
    struct cpu_surface surface = {.pixels = pixels};
    hrc_frame_info info = {.surface_width = 4, .surface_height = 3,
        .background_rgba = 0xffa35127, .command_count = 1, .upload_count = 1};
    hrc_upload u = {.pixels = atlas, .pixel_len = sizeof atlas};
    u.info.resource = u.info.generation = 1;
    u.info.width = 5; u.info.height = 4; u.info.stride = 6;
    u.info.format = HRC_ALPHA8;
    hrc_command c = {.tag = HRC_ALPHA_MASK, .resource = 1, .generation = 1,
        .source_x = 1, .source_y = 1, .source_width = 4, .source_height = 3,
        .destination_x = -1, .destination_y = -1,
        .destination_width = 4, .destination_height = 3,
        .clip_x = 1, .clip_width = 3, .clip_height = 3};
    for (unsigned alpha = 0; alpha < 256; alpha++) {
        c.color_rgba = alpha << 24 | 0x39a7ed;
        for (unsigned i = 0; i < 12; i++) {
            expected[4*i] = 0x27; expected[4*i+1] = 0x51;
            expected[4*i+2] = 0xa3; expected[4*i+3] = 255;
        }
        for (unsigned y = 0; y < 2; y++)
            for (unsigned x = 1; x < 3; x++)
                reference_blend(expected + (y*4+x)*4, c.color_rgba, atlas[(y+2)*6+x+2]);
        CHECK(cpu_paint(&surface, &info, &c, &u) == 0);
        CHECK(memcmp(pixels, expected, sizeof pixels) == 0);
    }
    u.pixel_len = 22; /* Last sampled byte is offset 22. */
    CHECK(cpu_paint(&surface, &info, &c, &u) != 0);
    u.pixel_len = sizeof atlas; u.info.width = 4;
    CHECK(cpu_paint(&surface, &info, &c, &u) != 0);
    u.info.width = 5; u.info.height = 3;
    CHECK(cpu_paint(&surface, &info, &c, &u) != 0);
    return 0;
}
int main(void) {
    CHECK(blend_equivalence() == 0);
    CHECK(mask_one_to_one() == 0);
    uint8_t pixels[16] = {0};
    struct cpu_surface surface = {.pixels = pixels};
    hrc_frame_info info = {.surface_width = 2, .surface_height = 2, .background_rgba = 0xff000000, .command_count = 1};
    hrc_command command = {.tag = HRC_SOLID, .color_rgba = 0x800000ff,
        .destination_width = 2, .destination_height = 2, .clip_width = 1, .clip_height = 1};
    CHECK(cpu_paint(&surface, &info, &command, NULL) == 0);
    CHECK(pixels[0] == 128 && pixels[1] == 0 && pixels[2] == 0 && pixels[3] == 255);
    CHECK(pixels[4] == 0 && pixels[7] == 255); /* clip, not just bounds */
    command.destination_x = -2;
    CHECK(cpu_paint(&surface, &info, &command, NULL) == 0);
    CHECK(pixels[0] == 0); /* entirely outside the surface */
    command.destination_x = 0;
    command.tag = HRC_ALPHA_MASK;
    command.resource = 1; command.generation = 1;
    command.source_width = command.source_height = 1;
    command.destination_width = command.destination_height = 1;
    command.color_rgba = 0xffff0000;
    CHECK(cpu_paint(&surface, &info, &command, NULL) != 0); /* missing resource */
    uint8_t alpha = 127;
    hrc_upload upload = {.pixels = &alpha, .pixel_len = 1};
    upload.info.resource = 1; upload.info.generation = 1;
    upload.info.width = upload.info.height = upload.info.stride = 1;
    upload.info.format = HRC_ALPHA8;
    info.upload_count = 1;
    CHECK(cpu_paint(&surface, &info, &command, &upload) == 0);
    CHECK(pixels[0] == 0 && pixels[2] == 127 && pixels[3] == 255);
    uint8_t rgba[4] = {0, 255, 0, 128};
    upload.pixels = rgba; upload.pixel_len = 4;
    upload.info.format = HRC_RGBA8; upload.info.stride = 4;
    command.tag = HRC_RGBA;
    CHECK(cpu_paint(&surface, &info, &command, &upload) == 0);
    CHECK(pixels[0] == 0 && pixels[1] == 128 && pixels[2] == 0);
    upload.pixel_len = 3;
    CHECK(cpu_paint(&surface, &info, &command, &upload) != 0);
    info.surface_width = CPU_MAX_SIDE + 1;
    CHECK(cpu_paint(&surface, &info, &command, &upload) != 0);
    puts("CPU_PASS: exhaustive alpha/coverage equivalence, clipping, alpha, RGBA, missing/truncated resources, bounds");
    return 0;
}
