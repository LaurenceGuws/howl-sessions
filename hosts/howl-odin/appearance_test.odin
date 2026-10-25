package main

import "core:testing"

@(test)
application_theme_ids_roundtrip_and_cycle :: proc(t: ^testing.T) {
	themes := [3]App_Theme{.Howl_Dark, .Slate, .High_Contrast}
	for theme in themes {
		parsed, ok := parse_app_theme(app_theme_id(theme))
		testing.expect(t, ok)
		testing.expect_value(t, parsed, theme)
	}
	testing.expect_value(t, next_app_theme(.Howl_Dark, 1), App_Theme.Slate)
	testing.expect_value(t, next_app_theme(.Slate, 1), App_Theme.High_Contrast)
	testing.expect_value(t, next_app_theme(.High_Contrast, 1), App_Theme.Howl_Dark)
	testing.expect_value(t, next_app_theme(.Howl_Dark, -1), App_Theme.High_Contrast)
}

@(test)
application_themes_change_chrome_but_keep_terminal_background_baseline :: proc(t: ^testing.T) {
	dark := palette_for_theme(.Howl_Dark)
	slate := palette_for_theme(.Slate)
	high := palette_for_theme(.High_Contrast)
	testing.expect(t, dark.title_bg != slate.title_bg)
	testing.expect(t, slate.accent != high.accent)
	testing.expect_value(t, dark.terminal_bg, slate.terminal_bg)
	testing.expect_value(t, dark.terminal_bg, high.terminal_bg)
}
