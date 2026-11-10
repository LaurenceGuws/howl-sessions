package main

import "core:fmt"
import "core:strings"

MAX_PROFILES :: 8
MAX_PROFILE_ENV :: 16
PROFILE_ID_BYTES :: 48
PROFILE_NAME_BYTES :: 80
PROFILE_SHELL_BYTES :: 512
PROFILE_COMMAND_BYTES :: 4096
PROFILE_CWD_BYTES :: 1024
PROFILE_ENDPOINT_BYTES :: 512
PROFILE_ENV_NAME_BYTES :: 128
PROFILE_ENV_VALUE_BYTES :: 2048

Profile_Mode :: enum u8 {
	Attach,
	Launch,
}

Profile_Env :: struct {
	name: [PROFILE_ENV_NAME_BYTES]u8,
	name_len: int,
	value: [PROFILE_ENV_VALUE_BYTES]u8,
	value_len: int,
}

Profile :: struct {
	built_in: bool,
	mode: Profile_Mode,
	id: [PROFILE_ID_BYTES]u8,
	id_len: int,
	name: [PROFILE_NAME_BYTES]u8,
	name_len: int,
	shell: [PROFILE_SHELL_BYTES]u8,
	shell_len: int,
	command: [PROFILE_COMMAND_BYTES]u8,
	command_len: int,
	cwd: [PROFILE_CWD_BYTES]u8,
	cwd_len: int,
	endpoint: [PROFILE_ENDPOINT_BYTES]u8,
	endpoint_len: int,
	env: [MAX_PROFILE_ENV]Profile_Env,
	env_count: int,
	font_pixels: u16,
}

User_Profile_Env_Config :: struct {
	name: string `json:"name"`,
	value: string `json:"value"`,
}

User_Profile_Config :: struct {
	id: string `json:"id"`,
	name: string `json:"name"`,
	mode: string `json:"mode"`,
	shell: string `json:"shell"`,
	command: string `json:"command"`,
	cwd: string `json:"cwd"`,
	endpoint: string `json:"endpoint"`,
	environment: []User_Profile_Env_Config `json:"environment"`,
	font_pixels: int `json:"font_pixels"`,
}

profile_set_text :: proc(destination: []u8, destination_len: ^int, value: string) -> bool {
	if destination_len == nil || len(value) >= len(destination) || strings.index_byte(value, 0) >= 0 {
		return false
	}
	if len(value) != 0 {
		copy(destination[:len(value)], transmute([]u8)value)
	}
	destination_len^ = len(value)
	return true
}

profile_text :: proc(buffer: []u8, count: int) -> string {
	if count <= 0 {
		return ""
	}
	return string(buffer[:min(count, len(buffer))])
}

profile_id :: proc(profile: ^Profile) -> string {
	return profile == nil ? "" : profile_text(profile.id[:], profile.id_len)
}

profile_name :: proc(profile: ^Profile) -> string {
	return profile == nil ? "" : profile_text(profile.name[:], profile.name_len)
}

profile_shell :: proc(profile: ^Profile) -> string {
	return profile == nil ? "" : profile_text(profile.shell[:], profile.shell_len)
}

profile_command :: proc(profile: ^Profile) -> string {
	return profile == nil ? "" : profile_text(profile.command[:], profile.command_len)
}

profile_cwd :: proc(profile: ^Profile) -> string {
	return profile == nil ? "" : profile_text(profile.cwd[:], profile.cwd_len)
}

profile_endpoint :: proc(profile: ^Profile) -> string {
	return profile == nil ? "" : profile_text(profile.endpoint[:], profile.endpoint_len)
}

profile_env_name :: proc(entry: ^Profile_Env) -> string {
	return entry == nil ? "" : profile_text(entry.name[:], entry.name_len)
}

profile_env_value :: proc(entry: ^Profile_Env) -> string {
	return entry == nil ? "" : profile_text(entry.value[:], entry.value_len)
}

valid_profile_id :: proc(value: string) -> bool {
	if len(value) == 0 || len(value) >= PROFILE_ID_BYTES {
		return false
	}
	for byte in transmute([]u8)value {
		if !(byte >= 'a' && byte <= 'z') && !(byte >= 'A' && byte <= 'Z') &&
		   !(byte >= '0' && byte <= '9') && byte != '-' && byte != '_' && byte != '.' {
			return false
		}
	}
	return true
}

valid_profile_font_pixels :: proc(value: int) -> bool {
	return value == 0 || valid_terminal_font_pixels(value)
}

profile_mode_text :: proc(mode: Profile_Mode) -> string {
	return mode == .Attach ? "attach" : "launch"
}

parse_profile_mode :: proc(value: string) -> (Profile_Mode, bool) {
	if strings.equal_fold(value, "attach") do return .Attach, true
	if strings.equal_fold(value, "launch") do return .Launch, true
	return .Attach, false
}

profile_index_by_id :: proc(app: ^App, id: string) -> int {
	if app == nil || len(id) == 0 {
		return -1
	}
	for index in 0..<app.profile_count {
		if profile_id(app.profiles[index]) == id {
			return index
		}
	}
	return -1
}

profile_at :: proc(app: ^App, index: int) -> ^Profile {
	if app == nil || index < 0 || index >= app.profile_count {
		return nil
	}
	return app.profiles[index]
}

initialize_builtin_profiles :: proc(app: ^App) -> bool {
	if app == nil {
		return false
	}
	destroy_profiles(app)
	home := new(Profile)
	if home == nil do return false
	home^ = Profile{built_in = true, mode = .Attach}
	if !profile_set_text(home.id[:], &home.id_len, "home") ||
	   !profile_set_text(home.name[:], &home.name_len, "Home Instance") ||
	   !profile_set_text(home.endpoint[:], &home.endpoint_len, HOME_ENDPOINT) {
		free(home)
		return false
	}
	app.profiles[0] = home
	local := new(Profile)
	if local == nil {
		free(home)
		app.profiles[0] = nil
		return false
	}
	local^ = Profile{built_in = true, mode = .Launch}
	if !profile_set_text(local.id[:], &local.id_len, "local") ||
	   !profile_set_text(local.name[:], &local.name_len, "Local shell") {
		free(local)
		free(home)
		app.profiles[0] = nil
		return false
	}
	app.profiles[1] = local
	app.profile_count = 2
	return true
}

destroy_profiles :: proc(app: ^App) {
	if app == nil {
		return
	}
	for profile, index in app.profiles {
		if profile != nil {
			free(profile)
			app.profiles[index] = nil
		}
	}
	app.profile_count = 0
}

profile_config_error :: proc(app: ^App, index: int, field: string) {
	if app == nil || app.config_notice_len != 0 {
		return
	}
	buffer: [192]u8
	message := fmt_profile_error(buffer[:], index, field)
	set_config_notice(app, message)
}

fmt_profile_error :: proc(buffer: []u8, index: int, field: string) -> string {
	return fmt.bprintf(buffer, "profiles[%d]: %s", index, field)
}

valid_profile_env_name :: proc(value: string) -> bool {
	if len(value) == 0 || len(value) >= PROFILE_ENV_NAME_BYTES {
		return false
	}
	for byte in transmute([]u8)value {
		if byte == 0 || byte == '=' {
			return false
		}
	}
	return true
}

profile_env_duplicate :: proc(profile: ^Profile, name: string) -> bool {
	if profile == nil {
		return false
	}
	for index in 0..<profile.env_count {
		if profile_env_name(&profile.env[index]) == name {
			return true
		}
	}
	return false
}

profile_from_config :: proc(app: ^App, config: User_Profile_Config, config_index: int) -> ^Profile {
	if app == nil || !valid_profile_id(config.id) {
		profile_config_error(app, config_index, "id")
		return nil
	}
	if profile_index_by_id(app, config.id) >= 0 {
		profile_config_error(app, config_index, "duplicate id")
		return nil
	}
	if len(config.name) == 0 || len(config.name) >= PROFILE_NAME_BYTES {
		profile_config_error(app, config_index, "name")
		return nil
	}
	mode, mode_ok := parse_profile_mode(config.mode)
	if !mode_ok {
		profile_config_error(app, config_index, "mode")
		return nil
	}
	if !valid_profile_font_pixels(config.font_pixels) {
		profile_config_error(app, config_index, "font_pixels")
		return nil
	}
	if mode == .Attach {
		if len(config.endpoint) == 0 || len(config.endpoint) >= PROFILE_ENDPOINT_BYTES {
			profile_config_error(app, config_index, "endpoint")
			return nil
		}
		if len(config.shell) != 0 || len(config.command) != 0 || len(config.cwd) != 0 || len(config.environment) != 0 {
			profile_config_error(app, config_index, "attach profile has launch fields")
			return nil
		}
	} else {
		if len(config.endpoint) != 0 {
			profile_config_error(app, config_index, "launch profile has endpoint")
			return nil
		}
		if len(config.shell) >= PROFILE_SHELL_BYTES || len(config.command) >= PROFILE_COMMAND_BYTES || len(config.cwd) >= PROFILE_CWD_BYTES {
			profile_config_error(app, config_index, "launch field too long")
			return nil
		}
		if len(config.environment) > MAX_PROFILE_ENV {
			profile_config_error(app, config_index, "environment")
			return nil
		}
	}

	profile := new(Profile)
	if profile == nil {
		profile_config_error(app, config_index, "allocation")
		return nil
	}
	profile^ = Profile{mode = mode, font_pixels = u16(config.font_pixels)}
	if !profile_set_text(profile.id[:], &profile.id_len, config.id) ||
	   !profile_set_text(profile.name[:], &profile.name_len, config.name) ||
	   !profile_set_text(profile.shell[:], &profile.shell_len, config.shell) ||
	   !profile_set_text(profile.command[:], &profile.command_len, config.command) ||
	   !profile_set_text(profile.cwd[:], &profile.cwd_len, config.cwd) ||
	   !profile_set_text(profile.endpoint[:], &profile.endpoint_len, config.endpoint) {
		free(profile)
		profile_config_error(app, config_index, "text")
		return nil
	}
	for entry, env_index in config.environment {
		if !valid_profile_env_name(entry.name) || len(entry.value) >= PROFILE_ENV_VALUE_BYTES || profile_env_duplicate(profile, entry.name) {
			free(profile)
			profile_config_error(app, config_index, "environment")
			return nil
		}
		target := &profile.env[env_index]
		if !profile_set_text(target.name[:], &target.name_len, entry.name) ||
		   !profile_set_text(target.value[:], &target.value_len, entry.value) {
			free(profile)
			profile_config_error(app, config_index, "environment")
			return nil
		}
		profile.env_count += 1
	}
	return profile
}

load_user_profiles :: proc(app: ^App, configs: []User_Profile_Config) -> bool {
	if app == nil do return false
	initial_count := app.profile_count
	for config, index in configs {
		if app.profile_count >= MAX_PROFILES {
			profile_config_error(app, index, "profile limit")
			for app.profile_count > initial_count {
				app.profile_count -= 1
				free(app.profiles[app.profile_count])
				app.profiles[app.profile_count] = nil
			}
			return false
		}
		profile := profile_from_config(app, config, index)
		if profile == nil {
			for app.profile_count > initial_count {
				app.profile_count -= 1
				free(app.profiles[app.profile_count])
				app.profiles[app.profile_count] = nil
			}
			return false
		}
		app.profiles[app.profile_count] = profile
		app.profile_count += 1
	}
	return true
}

default_profile_index_from_config :: proc(app: ^App, config: User_Config) -> (int, bool) {
	if app == nil || app.profile_count == 0 {
		set_config_notice(app, "default_profile: profile catalogue unavailable")
		return 0, false
	}
	if len(config.default_profile) != 0 {
		index := profile_index_by_id(app, config.default_profile)
		if index < 0 {
			set_config_notice(app, "default_profile: unknown profile id")
			return 0, false
		}
		return index, true
	}
	if config.startup_profile < 0 || config.startup_profile >= min(2, app.profile_count) {
		set_config_notice(app, "startup_profile: unavailable built-in profile")
		return 0, false
	}
	return config.startup_profile, true
}

profile_in_use :: proc(app: ^App, profile_index: int) -> bool {
	if app == nil || profile_index < 0 {
		return false
	}
	for tab_index in 0..<app.tab_count {
		tab := &app.tabs[tab_index]
		if tab.profile == profile_index {
			return true
		}
		for view in tab.panes {
			if view != nil && view.profile_index == profile_index {
				return true
			}
		}
	}
	return false
}

next_profile_id :: proc(app: ^App, output: []u8) -> (string, bool) {
	if app == nil || len(output) < 16 {
		return "", false
	}
	for identity in 1..=9999 {
		candidate := fmt.bprintf(output, "profile-%d", identity)
		if profile_index_by_id(app, candidate) < 0 {
			return candidate, true
		}
	}
	return "", false
}

create_user_profile :: proc(app: ^App) -> int {
	if app == nil || app.profile_count >= MAX_PROFILES {
		return -1
	}
	profile := new(Profile)
	if profile == nil {
		return -1
	}
	profile^ = Profile{mode = .Launch}
	id_storage: [PROFILE_ID_BYTES]u8
	id, ok := next_profile_id(app, id_storage[:])
	if !ok || !profile_set_text(profile.id[:], &profile.id_len, id) ||
	   !profile_set_text(profile.name[:], &profile.name_len, "New profile") {
		free(profile)
		return -1
	}
	index := app.profile_count
	app.profiles[index] = profile
	app.profile_count += 1
	return index
}

duplicate_user_profile :: proc(app: ^App, source_index: int) -> int {
	if app == nil || app.profile_count >= MAX_PROFILES {
		return -1
	}
	source := profile_at(app, source_index)
	if source == nil {
		return -1
	}
	profile := new(Profile)
	if profile == nil {
		return -1
	}
	profile^ = source^
	profile.built_in = false
	id_storage: [PROFILE_ID_BYTES]u8
	id, ok := next_profile_id(app, id_storage[:])
	if !ok || !profile_set_text(profile.id[:], &profile.id_len, id) {
		free(profile)
		return -1
	}
	name_storage: [PROFILE_NAME_BYTES]u8
	source_name := profile_name(source)
	if len(source_name) + len(" copy") >= PROFILE_NAME_BYTES {
		free(profile)
		return -1
	}
	name := fmt.bprintf(name_storage[:], "%s copy", source_name)
	if !profile_set_text(profile.name[:], &profile.name_len, name) {
		free(profile)
		return -1
	}
	index := app.profile_count
	app.profiles[index] = profile
	app.profile_count += 1
	return index
}

remap_profile_indices_after_delete :: proc(app: ^App, removed_index: int) {
	if app == nil {
		return
	}
	for tab_index in 0..<app.tab_count {
		tab := &app.tabs[tab_index]
		if tab.profile > removed_index do tab.profile -= 1
		for view in tab.panes {
			if view != nil && view.profile_index > removed_index do view.profile_index -= 1
		}
	}
	if app.startup_profile == removed_index {
		app.startup_profile = 0
	} else if app.startup_profile > removed_index {
		app.startup_profile -= 1
	}
}

delete_user_profile :: proc(app: ^App, profile_index: int) -> bool {
	profile := profile_at(app, profile_index)
	if app == nil || profile == nil || profile.built_in || profile_in_use(app, profile_index) {
		return false
	}
	free(profile)
	for index in profile_index..<app.profile_count - 1 {
		app.profiles[index] = app.profiles[index + 1]
	}
	app.profile_count -= 1
	app.profiles[app.profile_count] = nil
	remap_profile_indices_after_delete(app, profile_index)
	return true
}

profile_apply_font_to_views :: proc(app: ^App, profile_index: int) {
	if app == nil {
		return
	}
	profile := profile_at(app, profile_index)
	if profile == nil {
		return
	}
	for tab_index in 0..<app.tab_count {
		for view in app.tabs[tab_index].panes {
			if view != nil && view.profile_index == profile_index {
				view.profile_font_pixels = profile.font_pixels
				seed_view_terminal_font(app, view)
				refresh_terminal_presentation(app, view)
			}
		}
	}
}
