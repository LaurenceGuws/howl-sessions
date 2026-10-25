package main

import "core:testing"

@(test)
profile_catalog_loads_builtins_and_bounded_user_launch_recipe :: proc(t: ^testing.T) {
	app: App
	testing.expect(t, initialize_builtin_profiles(&app))
	defer destroy_profiles(&app)
	configs := [1]User_Profile_Config{{
		id = "lab",
		name = "Lab Recipe",
		mode = "launch",
		shell = "/bin/bash",
		command = "printf lab",
		cwd = "/tmp",
		environment = []User_Profile_Env_Config{
			{name = "HOWL_PROFILE_TEST", value = "green"},
		},
		font_pixels = 12,
	}}
	testing.expect(t, load_user_profiles(&app, configs[:]))
	testing.expect_value(t, app.profile_count, 3)
	profile := profile_at(&app, 2)
	testing.expect(t, profile != nil)
	testing.expect_value(t, profile_id(profile), "lab")
	testing.expect_value(t, profile_name(profile), "Lab Recipe")
	testing.expect_value(t, profile.mode, Profile_Mode.Launch)
	testing.expect_value(t, profile_command(profile), "printf lab")
	testing.expect_value(t, profile_cwd(profile), "/tmp")
	testing.expect_value(t, profile.env_count, 1)
	testing.expect_value(t, profile_env_name(&profile.env[0]), "HOWL_PROFILE_TEST")
	testing.expect_value(t, profile.font_pixels, u16(12))
}

@(test)
profile_catalog_rejects_entire_persisted_set_on_one_bad_entry :: proc(t: ^testing.T) {
	app: App
	testing.expect(t, initialize_builtin_profiles(&app))
	defer destroy_profiles(&app)
	configs := [2]User_Profile_Config{
		{id = "good", name = "Good attach", mode = "attach", endpoint = "unix:/tmp/good", font_pixels = 15},
		{id = "bad", name = "Bad attach", mode = "attach", endpoint = "unix:/tmp/a", command = "ignored"},
	}
	testing.expect(t, !load_user_profiles(&app, configs[:]))
	testing.expect_value(t, app.profile_count, 2)
	testing.expect_value(t, string(app.config_notice[:app.config_notice_len]), "profiles[1]: attach profile has launch fields")
}

@(test)
profile_catalog_rejects_duplicate_ids_and_invalid_environment_names :: proc(t: ^testing.T) {
	app: App
	testing.expect(t, initialize_builtin_profiles(&app))
	defer destroy_profiles(&app)
	duplicate := [1]User_Profile_Config{{id = "home", name = "Duplicate", mode = "attach", endpoint = "unix:/tmp/home"}}
	testing.expect(t, !load_user_profiles(&app, duplicate[:]))
	testing.expect_value(t, app.profile_count, 2)
	app.config_notice_len = 0
	bad_env := [1]User_Profile_Config{{
		id = "env",
		name = "Bad env",
		mode = "launch",
		environment = []User_Profile_Env_Config{{name = "BAD=NAME", value = "x"}},
	}}
	testing.expect(t, !load_user_profiles(&app, bad_env[:]))
	testing.expect_value(t, app.profile_count, 2)
	testing.expect_value(t, string(app.config_notice[:app.config_notice_len]), "profiles[0]: environment")
}

@(test)
default_profile_prefers_stable_id_then_legacy_builtin_index :: proc(t: ^testing.T) {
	app: App
	testing.expect(t, initialize_builtin_profiles(&app))
	defer destroy_profiles(&app)
	custom := [1]User_Profile_Config{{id = "lab", name = "Lab", mode = "launch"}}
	testing.expect(t, load_user_profiles(&app, custom[:]))
	config := User_Config{schema = 3, startup_profile = 0, default_profile = "lab"}
	index, ok := default_profile_index_from_config(&app, config)
	testing.expect(t, ok)
	testing.expect_value(t, index, 2)
	config.default_profile = ""
	config.startup_profile = 1
	index, ok = default_profile_index_from_config(&app, config)
	testing.expect(t, ok)
	testing.expect_value(t, index, 1)
}

@(test)
user_profile_create_duplicate_delete_preserves_live_recipe_indices :: proc(t: ^testing.T) {
	app: App
	testing.expect(t, initialize_builtin_profiles(&app))
	defer destroy_profiles(&app)
	created := create_user_profile(&app)
	testing.expect_value(t, created, 2)
	duplicate := duplicate_user_profile(&app, 1)
	testing.expect_value(t, duplicate, 3)
	testing.expect(t, !profile_at(&app, duplicate).built_in)
	testing.expect_value(t, profile_name(profile_at(&app, duplicate)), "Local shell copy")
	app.startup_profile = duplicate
	testing.expect(t, delete_user_profile(&app, created))
	testing.expect_value(t, app.profile_count, 3)
	testing.expect_value(t, app.startup_profile, 2)
	testing.expect_value(t, profile_name(profile_at(&app, 2)), "Local shell copy")
}

@(test)
profile_delete_refuses_builtin_and_live_instance_recipe :: proc(t: ^testing.T) {
	app: App
	testing.expect(t, initialize_builtin_profiles(&app))
	defer destroy_profiles(&app)
	created := create_user_profile(&app)
	testing.expect(t, !delete_user_profile(&app, 0))
	view := new(Instance_View)
	defer free(view)
	view.profile_index = created
	app.tab_count = 1
	app.tabs[0].pane_count = 1
	app.tabs[0].panes[0] = view
	testing.expect(t, !delete_user_profile(&app, created))
	app.tabs[0].panes[0] = nil
	app.tab_count = 0
	testing.expect(t, delete_user_profile(&app, created))
}

@(test)
profile_font_pixels_accept_inherit_or_any_global_range_value :: proc(t: ^testing.T) {
	testing.expect(t, valid_profile_font_pixels(0))
	values := [5]int{8, 13, 17, 31, 48}
	for value in values do testing.expect(t, valid_profile_font_pixels(value))
	testing.expect(t, !valid_profile_font_pixels(7))
	testing.expect(t, !valid_profile_font_pixels(49))
}

@(test)
profile_font_edit_resets_local_zoom_for_matching_live_terminals :: proc(t: ^testing.T) {
    app := App{terminal_font_pixels = 15}
    testing.expect(t, initialize_builtin_profiles(&app))
    defer destroy_profiles(&app)
    view := Instance_View{
        profile_index = 1,
        profile_font_pixels = 0,
        terminal_font_pixels = 22,
        terminal_font_overridden = true,
    }
    app.tab_count = 1
    app.tabs[0].pane_count = 1
    app.tabs[0].panes[0] = &view

    profile := profile_at(&app, 1)
    profile.font_pixels = 17
    profile_apply_font_to_views(&app, 1)

    testing.expect_value(t, view.profile_font_pixels, u16(17))
    testing.expect_value(t, view.terminal_font_pixels, u16(17))
    testing.expect(t, !view.terminal_font_overridden)
}
