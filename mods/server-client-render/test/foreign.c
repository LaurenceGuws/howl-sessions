#include "howl_server_client.h"
#include "howl_server_client_render.h"
#include <string.h>

_Static_assert(sizeof(hrc_command) == 64, "Render command ABI changed");
_Static_assert(sizeof(hrc_resource) == 40, "Render resource ABI changed");
_Static_assert(sizeof(hrc_frame_info) == 72, "Render frame metadata ABI changed");

int main(int argc, char **argv) {
    if (argc != 2 || hsc_abi_version() != HSC_ABI_VERSION ||
        hsr_abi_version() != HSR_ABI_VERSION) return 1;
    hsr_renderer *owner = 0;
    if (hsr_create(HSR_ABI_VERSION + 1, 0, &owner) != HSR_VERSION_MISMATCH || owner) return 2;
    hsr_config config = {
        .primary = {(const uint8_t *)argv[1], strlen(argv[1])},
        .pixel_size = 16
    };
    const hsr_bytes fallback = {(const uint8_t *)argv[1], strlen(argv[1])};
    config.fallbacks = &fallback;
    config.fallback_count = 25;
    if (hsr_create(HSR_ABI_VERSION, &config, &owner) != HSR_INVALID_ARGUMENT || owner) return 3;
    config.fallback_count = 1;
    if (hsr_create(HSR_ABI_VERSION, &config, &owner) != HSR_OK || !owner) return 3;
    hrc_cell_size size = {0};
    if (hsr_cell_size(owner, &size) != HSR_OK || !size.width || !size.height) return 4;
    hsr_frame *frame = 0;
    if (hsr_capture(owner, 0, 0, 0, &frame) != HSR_INVALID_ARGUMENT || frame) return 5;
    hrc_frame_view view = {0};
    if (hsr_frame_read(0, &view) != HSR_INVALID_ARGUMENT || view.info.revision) return 6;
    hsr_frame_release(&frame);
    if (hsr_try_destroy(&owner) != HSR_OK || owner) return 7;
    hsr_family_config family = {.pixel_size = 16};
    if (hsr_create_family(HSR_ABI_VERSION + 1, 0, &owner) != HSR_VERSION_MISMATCH || owner) return 8;
    if (hsr_create_family(HSR_ABI_VERSION, &family, &owner) != HSR_INVALID_ARGUMENT || owner) return 9;
    for (size_t i = 0; i < 4; i++) family.fonts[i].primary = config.primary;
    family.fonts[2].fallback_count = 25;
    if (hsr_create_family(HSR_ABI_VERSION, &family, &owner) != HSR_INVALID_ARGUMENT || owner) return 10;
    family.fonts[2].fallback_count = 0;
    family.reserved = 1;
    if (hsr_create_family(HSR_ABI_VERSION, &family, &owner) != HSR_INVALID_ARGUMENT || owner) return 11;
    family.reserved = 0;
    if (hsr_create_family(HSR_ABI_VERSION, &family, &owner) != HSR_OK || !owner) return 12;
    hrc_cell_size family_size = {0};
    if (hsr_cell_size(owner, &family_size) != HSR_OK ||
        family_size.width != size.width || family_size.height != size.height) return 13;
    if (hsr_try_destroy(&owner) != HSR_OK || owner) return 14;
    memset(&family.fonts[1], 0, 3 * sizeof(family.fonts[0]));
    if (hsr_create_family(HSR_ABI_VERSION, &family, &owner) != HSR_OK || !owner) return 15;
    if (hsr_try_destroy(&owner) != HSR_OK || owner) return 16;
    return 0;
}
