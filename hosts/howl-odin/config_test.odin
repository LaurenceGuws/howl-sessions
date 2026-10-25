package main

import "core:testing"

config_diagnostic_text :: proc(buffer: ^[192]u8) -> string {
    used := 0
    for used < len(buffer) && buffer[used] != 0 do used += 1
    return string(buffer[:used])
}

@(test)
persisted_config_rejects_invalid_fields_instead_of_falling_back :: proc(t: ^testing.T) {
    diagnostic: [192]u8

    _, ok := user_config_from_candidate(
        {schema = 99, terminal_font_pixels = 15, startup_profile = 0},
        diagnostic[:],
    )
    testing.expect(t, !ok)
    testing.expect_value(t, config_diagnostic_text(&diagnostic), "config schema is unsupported")

    diagnostic = {}
    _, ok = user_config_from_candidate(
        {schema = CONFIG_SCHEMA, terminal_font_pixels = 7, startup_profile = 0, app_theme = "howl_dark"},
        diagnostic[:],
    )
    testing.expect(t, !ok)
    testing.expect_value(t, config_diagnostic_text(&diagnostic), "terminal_font_pixels is invalid")

    diagnostic = {}
    _, ok = user_config_from_candidate(
        {schema = CONFIG_SCHEMA, terminal_font_pixels = 15, startup_profile = 2, app_theme = "howl_dark"},
        diagnostic[:],
    )
    testing.expect(t, !ok)
    testing.expect_value(t, config_diagnostic_text(&diagnostic), "startup_profile is invalid")

    diagnostic = {}
    _, ok = user_config_from_candidate(
        {schema = CONFIG_SCHEMA, terminal_font_pixels = 15, startup_profile = 0, app_theme = "not-a-theme"},
        diagnostic[:],
    )
    testing.expect(t, !ok)
    testing.expect_value(t, config_diagnostic_text(&diagnostic), "app_theme is invalid")
}

@(test)
persisted_config_accepts_exact_valid_values_without_substitution :: proc(t: ^testing.T) {
    diagnostic: [192]u8
    candidate := User_Config{
        schema = CONFIG_SCHEMA,
        terminal_font_pixels = 23,
        startup_profile = 1,
        app_theme = "high_contrast",
        default_profile = "local",
    }
    value, ok := user_config_from_candidate(candidate, diagnostic[:])
    testing.expect(t, ok)
    testing.expect_value(t, value.terminal_font_pixels, 23)
    testing.expect_value(t, value.startup_profile, 1)
    testing.expect_value(t, value.app_theme, "high_contrast")
    testing.expect_value(t, value.default_profile, "local")
}

@(test)
persisted_font_recipe_rejects_missing_explicit_file :: proc(t: ^testing.T) {
	diagnostic: [192]u8
	_, ok := user_config_from_candidate(
		{
			schema = CONFIG_SCHEMA,
			terminal_font_pixels = 15,
			startup_profile = 0,
			app_theme = "howl_dark",
			font = {regular = "/definitely/missing/howl-font.ttf"},
		},
		diagnostic[:],
	)
	testing.expect(t, !ok)
	testing.expect_value(t, config_diagnostic_text(&diagnostic), "font.regular must be an existing absolute path within the path limit")
}

@(test)
persisted_font_recipe_accepts_blank_inheritance :: proc(t: ^testing.T) {
	diagnostic: [192]u8
	value, ok := user_config_from_candidate(
		{
			schema = CONFIG_SCHEMA,
			terminal_font_pixels = 15,
			startup_profile = 0,
			app_theme = "howl_dark",
			font = {},
		},
		diagnostic[:],
	)
	testing.expect(t, ok)
	testing.expect_value(t, value.font.regular, "")
	testing.expect_value(t, value.font.fallback, "")
}
