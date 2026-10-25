package main

import "core:testing"

@(test)
profile_editor_respects_builtin_and_mode_field_ownership :: proc(t: ^testing.T) {
	app: App
	testing.expect(t, initialize_builtin_profiles(&app))
	defer destroy_profiles(&app)
	app.settings_profile_selection = 0
	testing.expect(t, !begin_profile_edit(&app, .Name))
	copy_index := duplicate_user_profile(&app, 0)
	testing.expect(t, copy_index >= 0)
	app.settings_profile_selection = copy_index
	profile := selected_settings_profile(&app)
	testing.expect(t, profile != nil && !profile.built_in && profile.mode == .Attach)
	testing.expect(t, profile_text_field_editable(profile, .Name))
	testing.expect(t, profile_text_field_editable(profile, .Endpoint))
	testing.expect(t, !profile_text_field_editable(profile, .Command))
}

@(test)
profile_editor_copies_bounded_source_and_backspaces_utf8_scalar :: proc(t: ^testing.T) {
	app: App
	testing.expect(t, initialize_builtin_profiles(&app))
	defer destroy_profiles(&app)
	copy_index := duplicate_user_profile(&app, 1)
	testing.expect(t, copy_index >= 0)
	app.settings_profile_selection = copy_index
	testing.expect(t, begin_profile_edit(&app, .Name))
	testing.expect_value(t, string(app.settings_profile_edit_buffer[:app.settings_profile_edit_len]), "Local shell copy")
	app.settings_profile_edit_len = 0
	testing.expect(t, append_profile_edit_text(&app, "aé界"))
	testing.expect_value(t, string(app.settings_profile_edit_buffer[:app.settings_profile_edit_len]), "aé界")
	testing.expect(t, backspace_profile_edit(&app))
	testing.expect_value(t, string(app.settings_profile_edit_buffer[:app.settings_profile_edit_len]), "aé")
}

@(test)
profile_editor_environment_name_conflict_ignores_current_entry_only :: proc(t: ^testing.T) {
	profile: Profile = {mode = .Launch}
	profile.env_count = 2
	testing.expect(t, profile_set_text(profile.env[0].name[:], &profile.env[0].name_len, "ONE"))
	testing.expect(t, profile_set_text(profile.env[1].name[:], &profile.env[1].name_len, "TWO"))
	testing.expect(t, !profile_env_name_conflict(&profile, "ONE", 0))
	testing.expect(t, profile_env_name_conflict(&profile, "TWO", 0))
	testing.expect(t, !profile_env_name_conflict(&profile, "THREE", 0))
}

@(test)
profile_editor_field_relevance_tracks_launch_vs_attach :: proc(t: ^testing.T) {
	profile: Profile = {mode = .Launch}
	testing.expect(t, profile_field_relevant(&profile, .Shell))
	testing.expect(t, !profile_field_relevant(&profile, .Endpoint))
	profile.mode = .Attach
	testing.expect(t, !profile_field_relevant(&profile, .Shell))
	testing.expect(t, profile_field_relevant(&profile, .Endpoint))
	testing.expect(t, profile_field_relevant(&profile, .Name))
	testing.expect(t, profile_field_relevant(&profile, .Font))
}

@(test)
profile_font_editor_parses_numeric_override_or_blank_inherit :: proc(t: ^testing.T) {
	pixels, ok := parse_profile_font_pixels("")
	testing.expect(t, ok)
	testing.expect_value(t, pixels, u16(0))

	pixels, ok = parse_profile_font_pixels("17")
	testing.expect(t, ok)
	testing.expect_value(t, pixels, u16(17))

	_, low := parse_profile_font_pixels("7")
	_, high := parse_profile_font_pixels("49")
	_, text := parse_profile_font_pixels("large")
	testing.expect(t, !low && !high && !text)
}
