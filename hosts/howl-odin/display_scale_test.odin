package main

import "core:c"
import "core:math"
import "core:testing"

@(test)
display_scale_keeps_logical_font_identity_at_one_x :: proc(t: ^testing.T) {
    pixels, ok := scaled_canvas_font_pixels(15, 1)
    testing.expect(t, ok)
    testing.expect_value(t, pixels, u16(15))
}

@(test)
display_scale_rounds_terminal_raster_to_backing_pixels :: proc(t: ^testing.T) {
    pixels_150, ok_150 := scaled_canvas_font_pixels(15, 1.5)
    pixels_200, ok_200 := scaled_canvas_font_pixels(15, 2)
    pixels_fraction, ok_fraction := scaled_canvas_font_pixels(18, 1.25)
    testing.expect(t, ok_150)
    testing.expect(t, ok_200)
    testing.expect(t, ok_fraction)
    testing.expect_value(t, pixels_150, u16(23))
    testing.expect_value(t, pixels_200, u16(30))
    testing.expect_value(t, pixels_fraction, u16(23))
}

@(test)
display_scale_rejects_invalid_or_hostile_values :: proc(t: ^testing.T) {
    _, zero_ok := scaled_canvas_font_pixels(15, 0)
    _, negative_ok := scaled_canvas_font_pixels(15, -1)
    _, huge_ok := scaled_canvas_font_pixels(15, CANVAS_SCALE_MAX + 1)
    _, zero_font_ok := scaled_canvas_font_pixels(0, 1)
    testing.expect(t, !zero_ok)
    testing.expect(t, !negative_ok)
    testing.expect(t, !huge_ok)
    testing.expect(t, !zero_font_ok)
}

@(test)
display_scale_maps_sdl_ttf_dpi_from_logical_points :: proc(t: ^testing.T) {
    dpi_100, ok_100 := scaled_text_dpi(1)
    dpi_150, ok_150 := scaled_text_dpi(1.5)
    dpi_200, ok_200 := scaled_text_dpi(2)
    testing.expect(t, ok_100)
    testing.expect(t, ok_150)
    testing.expect(t, ok_200)
    testing.expect_value(t, dpi_100, c.int(72))
    testing.expect_value(t, dpi_150, c.int(108))
    testing.expect_value(t, dpi_200, c.int(144))
}

@(test)
display_scale_rejects_invalid_sdl_ttf_dpi :: proc(t: ^testing.T) {
    _, zero_ok := scaled_text_dpi(0)
    _, nan_ok := scaled_text_dpi(math.nan_f32())
    _, huge_ok := scaled_text_dpi(CANVAS_SCALE_MAX + 1)
    testing.expect(t, !zero_ok)
    testing.expect(t, !nan_ok)
    testing.expect(t, !huge_ok)
}

@(test)
terminal_font_pixels_are_continuous_inside_one_bounded_range :: proc(t: ^testing.T) {
    valid := [7]int{8, 9, 13, 17, 23, 47, 48}
    for value in valid do testing.expect(t, valid_terminal_font_pixels(value))
    testing.expect(t, !valid_terminal_font_pixels(7))
    testing.expect(t, !valid_terminal_font_pixels(49))

    testing.expect_value(t, next_terminal_font_pixels(15, 1), u16(16))
    testing.expect_value(t, next_terminal_font_pixels(15, -1), u16(14))
    testing.expect_value(t, next_terminal_font_pixels(8, -1), u16(8))
    testing.expect_value(t, next_terminal_font_pixels(48, 1), u16(48))
}

@(test)
terminal_zoom_is_owned_by_only_the_active_terminal :: proc(t: ^testing.T) {
    first := Instance_View{terminal_font_pixels = 15}
    second := Instance_View{terminal_font_pixels = 15}
    app := App{terminal_font_pixels = 15, tab_count = 2, active_tab = 0}
    app.tabs[0].pane_count = 1
    app.tabs[0].panes[0] = &first
    app.tabs[1].pane_count = 1
    app.tabs[1].panes[0] = &second

    adjust_active_terminal_font(&app, 1)

    testing.expect_value(t, first.terminal_font_pixels, u16(16))
    testing.expect(t, first.terminal_font_overridden)
    testing.expect_value(t, second.terminal_font_pixels, u16(15))
    testing.expect(t, !second.terminal_font_overridden)
    testing.expect_value(t, app.terminal_font_pixels, u16(15))
}

@(test)
global_font_default_updates_only_inheriting_unzoomed_terminals :: proc(t: ^testing.T) {
    inherited := Instance_View{terminal_font_pixels = 15}
    zoomed := Instance_View{terminal_font_pixels = 18, terminal_font_overridden = true}
    profile := Instance_View{profile_font_pixels = 13, terminal_font_pixels = 13}
    app := App{terminal_font_pixels = 15, tab_count = 3}
    app.tabs[0].pane_count = 1
    app.tabs[0].panes[0] = &inherited
    app.tabs[1].pane_count = 1
    app.tabs[1].panes[0] = &zoomed
    app.tabs[2].pane_count = 1
    app.tabs[2].panes[0] = &profile

    apply_default_terminal_font_pixels(&app, 16)

    testing.expect_value(t, app.terminal_font_pixels, u16(16))
    testing.expect_value(t, inherited.terminal_font_pixels, u16(16))
    testing.expect_value(t, zoomed.terminal_font_pixels, u16(18))
    testing.expect_value(t, profile.terminal_font_pixels, u16(13))
}
