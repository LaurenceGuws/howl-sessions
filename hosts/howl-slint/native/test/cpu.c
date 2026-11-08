#include "cpu.h"
#include <stdio.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "CPU test line %d\n", __LINE__); return 1; } } while (0)
int main(void) {
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
    puts("CPU_PASS: clipping, alpha, RGBA, missing/truncated resources, bounds");
    return 0;
}
