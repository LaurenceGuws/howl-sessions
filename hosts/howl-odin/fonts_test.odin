package main

import "core:testing"

@(test)
desktop_font_path_copy_is_bounded_and_requires_real_files :: proc(t: ^testing.T) {
	storage: [FONT_PATH_BYTES]u8
	used := 0
	testing.expect(t, !copy_font_path(storage[:], &used, "/definitely/missing/howl-font.ttf"))
	testing.expect_value(t, used, 0)
}

@(test)
desktop_fontconfig_parser_accepts_exact_family_and_path :: proc(t: ^testing.T) {
	path, ok := fontconfig_output_path(
		"Noto Sans CJK JP,Noto Sans CJK JP Medium\n/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc\n",
		"Noto Sans CJK JP",
	)
	testing.expect(t, ok)
	testing.expect_value(t, path, "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc")
}

@(test)
desktop_fontconfig_parser_rejects_silent_family_substitution :: proc(t: ^testing.T) {
	_, ok := fontconfig_output_path(
		"DejaVu Sans\n/usr/share/fonts/TTF/DejaVuSans.ttf\n",
		"Noto Sans Arabic",
	)
	testing.expect(t, !ok)
}

@(test)
desktop_fontconfig_parser_rejects_missing_path_line :: proc(t: ^testing.T) {
	_, ok := fontconfig_output_path("Noto Sans Arabic\n", "Noto Sans Arabic")
	testing.expect(t, !ok)
}

@(test)
desktop_fontconfig_style_parser_requires_family_style_and_path :: proc(t: ^testing.T) {
	path, ok := fontconfig_style_output_path(
		"JetBrainsMono Nerd Font,JetBrainsMono NF\nBold Italic\n/usr/share/fonts/TTF/JetBrainsMonoNerdFont-BoldItalic.ttf\n",
		"JetBrainsMono Nerd Font",
		"Bold Italic",
	)
	testing.expect(t, ok)
	testing.expect_value(t, path, "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-BoldItalic.ttf")
	_, wrong_style := fontconfig_style_output_path(
		"JetBrainsMono Nerd Font\nBold Italic\n/font.ttf\n",
		"JetBrainsMono Nerd Font",
		"Italic",
	)
	testing.expect(t, !wrong_style)
}

font_test_store :: proc(output: []u8, used: ^int, value: string) {
	used^ = len(value)
	copy(output[:len(value)], transmute([]u8)value)
	if len(value) < len(output) do output[len(value)] = 0
}

@(test)
font_recipe_custom_regular_does_not_cross_mix_discovered_styles :: proc(t: ^testing.T) {
	defaults, overrides: Desktop_Fonts
	font_test_store(defaults.primary[:], &defaults.primary_len, "/fonts/base.ttf")
	font_test_store(defaults.italic[:], &defaults.italic_len, "/fonts/base-italic.ttf")
	font_test_store(defaults.bold[:], &defaults.bold_len, "/fonts/base-bold.ttf")
	font_test_store(defaults.bold_italic[:], &defaults.bold_italic_len, "/fonts/base-bold-italic.ttf")
	font_test_store(defaults.fallback[:], &defaults.fallback_len, "/fonts/arabic.ttf")
	font_test_store(defaults.secondary[:], &defaults.secondary_len, "/fonts/cjk.ttc")

	testing.expect_value(t, effective_terminal_primary_font(&defaults, &overrides), "/fonts/base.ttf")
	testing.expect_value(t, effective_terminal_italic_font(&defaults, &overrides), "/fonts/base-italic.ttf")

	font_test_store(overrides.primary[:], &overrides.primary_len, "/fonts/custom.ttf")
	testing.expect_value(t, effective_terminal_primary_font(&defaults, &overrides), "/fonts/custom.ttf")
	testing.expect_value(t, effective_terminal_italic_font(&defaults, &overrides), "")
	testing.expect_value(t, effective_terminal_bold_font(&defaults, &overrides), "")
	testing.expect_value(t, effective_terminal_bold_italic_font(&defaults, &overrides), "")
	testing.expect_value(t, effective_terminal_fallback_font(&defaults, &overrides), "/fonts/arabic.ttf")
	testing.expect_value(t, effective_terminal_secondary_fallback_font(&defaults, &overrides), "/fonts/cjk.ttc")

	font_test_store(overrides.italic[:], &overrides.italic_len, "/fonts/custom-italic.ttf")
	testing.expect_value(t, effective_terminal_italic_font(&defaults, &overrides), "/fonts/custom-italic.ttf")
}

@(test)
font_recipe_blank_overrides_roundtrip_as_inheritance :: proc(t: ^testing.T) {
	overrides: Desktop_Fonts
	config := font_config_from_overrides(&overrides)
	testing.expect_value(t, config.regular, "")
	testing.expect_value(t, config.italic, "")
	testing.expect_value(t, config.bold, "")
	testing.expect_value(t, config.bold_italic, "")
	testing.expect_value(t, config.fallback, "")
	testing.expect_value(t, config.secondary_fallback, "")

	testing.expect(t, copy_optional_font_path(overrides.primary[:], &overrides.primary_len, ""))
	testing.expect_value(t, overrides.primary_len, 0)
	testing.expect(t, !copy_optional_font_path(
		overrides.primary[:],
		&overrides.primary_len,
		"/definitely/missing/howl-font.ttf",
	))
}
