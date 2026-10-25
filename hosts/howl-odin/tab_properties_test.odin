package main

import "core:testing"

@(test)
canonical_title_follows_active_pane_without_overwriting_profile :: proc(t: ^testing.T) {
    a, b: Instance_View
    copy(a.display_title[:], "compile A"); a.display_title_len = 9; a.task_progress = (1 << 8) | 63
    copy(b.display_title[:], "other B"); b.display_title_len = 7; b.task_progress = (4 << 8) | 25
    tab := Tab{title = "Local shell", pane_count = 2}
    tab.panes[0] = &a; tab.panes[1] = &b
    output: [1024]u8
    title, progress := tab_property_presentation(&tab, output[:])
    testing.expect_value(t, title, "compile A")
    testing.expect_value(t, progress, u16((1 << 8) | 63))
    tab.active_pane = 1
    title, progress = tab_property_presentation(&tab, output[:])
    testing.expect_value(t, title, "other B")
    testing.expect_value(t, progress, u16((4 << 8) | 25))
    b.display_title_len = 0; b.task_progress = 0
    title, progress = tab_property_presentation(&tab, output[:])
    testing.expect_value(t, title, "")
    testing.expect_value(t, progress, u16(0))
    testing.expect_value(t, tab.title, "Local shell")
}

@(test)
progress_geometry_is_bounded_and_indeterminate_has_no_clock :: proc(t: ^testing.T) {
    x, width, visible := tab_progress_fraction((1 << 8) | 63)
    testing.expect_value(t, x, f32(0)); testing.expect_value(t, width, f32(0.63)); testing.expect(t, visible)
    x, width, visible = tab_progress_fraction(3 << 8)
    testing.expect_value(t, x, f32(1.0 / 3.0)); testing.expect_value(t, width, f32(1.0 / 3.0)); testing.expect(t, visible)
    invalid := [3]u16{0, (5 << 8) | 20, (1 << 8) | 101}
    for bad in invalid {
        _, _, shown := tab_progress_fraction(bad)
        testing.expect(t, !shown)
    }
}


@(test)
progress_strip_does_not_overlap_active_tab_underline :: proc(t: ^testing.T) {
    track := tab_progress_track(tab_rect_for_index(0))
    testing.expect(t, track.y + track.h < 37)
    testing.expect(t, track.w > 0)
    testing.expect_value(t, track.h, f32(2))
}
