package main

import "core:c"
import "core:fmt"
import "core:strconv"
import SDL "vendor:sdl3"

Profile_Edit_Field :: enum u8 {
	Name,
	Mode,
	Shell,
	Command,
	Cwd,
	Endpoint,
	Font,
	Env_Name,
	Env_Value,
}

PROFILE_EDIT_FIELD_COUNT :: 9
PROFILE_EDIT_BYTES :: PROFILE_COMMAND_BYTES

profile_edit_field_at :: proc(index: int) -> (Profile_Edit_Field, bool) {
	if index < 0 || index >= PROFILE_EDIT_FIELD_COUNT {
		return .Name, false
	}
	return Profile_Edit_Field(index), true
}

selected_settings_profile :: proc(app: ^App) -> ^Profile {
	if app == nil {
		return nil
	}
	return profile_at(app, app.settings_profile_selection)
}

profile_field_label :: proc(field: Profile_Edit_Field, env_index, env_count: int, storage: []u8) -> string {
	switch field {
	case .Name:     return "Name"
	case .Mode:     return "Mode"
	case .Shell:    return "Shell"
	case .Command:  return "Command"
	case .Cwd:      return "Working directory"
	case .Endpoint: return "Endpoint"
	case .Font:     return "Font size"
	case .Env_Name:
		if env_count == 0 do return "Env name"
		return fmt.bprintf(storage, "Env name  %d/%d", env_index + 1, env_count)
	case .Env_Value:
		if env_count == 0 do return "Env value"
		return fmt.bprintf(storage, "Env value  %d/%d", env_index + 1, env_count)
	}
	return ""
}

profile_font_label :: proc(font_pixels: u16, storage: []u8) -> string {
	if font_pixels == 0 do return "Inherit global"
	return fmt.bprintf(storage, "%d px", font_pixels)
}

parse_profile_font_pixels :: proc(value: string) -> (u16, bool) {
	if len(value) == 0 do return 0, true
	parsed, ok := strconv.parse_u64_of_base(value, 10)
	if !ok || parsed > 0xffff || !valid_profile_font_pixels(int(parsed)) do return 0, false
	return u16(parsed), true
}

profile_field_value :: proc(profile: ^Profile, field: Profile_Edit_Field, env_index: int, storage: []u8) -> string {
	if profile == nil {
		return ""
	}
	switch field {
	case .Name:     return profile_name(profile)
	case .Mode:     return profile.mode == .Launch ? "Launch" : "Attach"
	case .Shell:
		if profile.mode != .Launch do return "Not used by attach profiles"
		value := profile_shell(profile)
		return len(value) == 0 ? "Inherit $SHELL" : value
	case .Command:
		if profile.mode != .Launch do return "Not used by attach profiles"
		value := profile_command(profile)
		return len(value) == 0 ? "Interactive shell" : value
	case .Cwd:
		if profile.mode != .Launch do return "Not used by attach profiles"
		value := profile_cwd(profile)
		return len(value) == 0 ? "Inherit desktop cwd" : value
	case .Endpoint:
		if profile.mode != .Attach do return "Not used by launch profiles"
		return profile_endpoint(profile)
	case .Font:
		return profile_font_label(profile.font_pixels, storage)
	case .Env_Name:
		if profile.mode != .Launch do return "Not used by attach profiles"
		if profile.env_count == 0 do return "No environment overrides"
		index := clamp(env_index, 0, profile.env_count - 1)
		return profile_env_name(&profile.env[index])
	case .Env_Value:
		if profile.mode != .Launch do return "Not used by attach profiles"
		if profile.env_count == 0 do return "Press N to add an override"
		index := clamp(env_index, 0, profile.env_count - 1)
		return profile_env_value(&profile.env[index])
	}
	return ""
}

profile_text_field_editable :: proc(profile: ^Profile, field: Profile_Edit_Field) -> bool {
	if profile == nil || profile.built_in {
		return false
	}
	switch field {
	case .Name:
		return true
	case .Shell, .Command, .Cwd:
		return profile.mode == .Launch
	case .Endpoint:
		return profile.mode == .Attach
	case .Env_Name, .Env_Value:
		return profile.mode == .Launch && profile.env_count != 0
	case .Font:
		return true
	case .Mode:
		return false
	}
	return false
}

profile_edit_field_capacity :: proc(field: Profile_Edit_Field) -> int {
	switch field {
	case .Name:      return PROFILE_NAME_BYTES - 1
	case .Shell:     return PROFILE_SHELL_BYTES - 1
	case .Command:   return PROFILE_COMMAND_BYTES - 1
	case .Cwd:       return PROFILE_CWD_BYTES - 1
	case .Endpoint:  return PROFILE_ENDPOINT_BYTES - 1
	case .Env_Name:  return PROFILE_ENV_NAME_BYTES - 1
	case .Env_Value: return PROFILE_ENV_VALUE_BYTES - 1
	case .Font:      return 2
	case .Mode:
		return 0
	}
	return 0
}

profile_edit_field_source :: proc(profile: ^Profile, field: Profile_Edit_Field, env_index: int, storage: []u8) -> string {
	if profile == nil {
		return ""
	}
	switch field {
	case .Name:     return profile_name(profile)
	case .Shell:    return profile_shell(profile)
	case .Command:  return profile_command(profile)
	case .Cwd:      return profile_cwd(profile)
	case .Endpoint: return profile_endpoint(profile)
	case .Env_Name:
		if profile.env_count == 0 do return ""
		return profile_env_name(&profile.env[clamp(env_index, 0, profile.env_count - 1)])
	case .Font:
		if profile.font_pixels == 0 do return ""
		return fmt.bprintf(storage, "%d", profile.font_pixels)
	case .Env_Value:
		if profile.env_count == 0 do return ""
		return profile_env_value(&profile.env[clamp(env_index, 0, profile.env_count - 1)])
	case .Mode:
		return ""
	}
	return ""
}

cancel_profile_edit :: proc(app: ^App) {
	if app == nil {
		return
	}
	app.settings_profile_editing = false
	app.settings_profile_select_all = false
	app.settings_profile_edit_len = 0
	clear_ime_preedit(app)
}

begin_profile_edit :: proc(app: ^App, field: Profile_Edit_Field) -> bool {
	profile := selected_settings_profile(app)
	if !profile_text_field_editable(profile, field) {
		if profile != nil && profile.built_in {
			set_settings_notice(app, "Built-in profile · duplicate it to customize")
		}
		return false
	}
	source_storage: [16]u8
	source := profile_edit_field_source(profile, field, app.settings_profile_env_selection, source_storage[:])
	capacity := profile_edit_field_capacity(field)
	if capacity <= 0 || len(source) > capacity || len(source) >= len(app.settings_profile_edit_buffer) {
		set_settings_notice(app, "Profile field exceeds editor bound")
		return false
	}
	app.settings_profile_edit_len = len(source)
	if len(source) != 0 {
		copy(app.settings_profile_edit_buffer[:len(source)], transmute([]u8)source)
	}
	app.settings_profile_edit_field = field
	app.settings_profile_edit_env_index = app.settings_profile_env_selection
	app.settings_profile_editing = true
	app.settings_profile_select_all = len(source) > 0
	app.settings_notice_len = 0
	clear_ime_preedit(app)
	return true
}

append_profile_edit_text :: proc(app: ^App, text: string) -> bool {
	if app == nil || !app.settings_profile_editing || len(text) == 0 {
		return false
	}
	capacity := profile_edit_field_capacity(app.settings_profile_edit_field)
	used := app.settings_profile_select_all ? 0 : app.settings_profile_edit_len
	if used + len(text) > capacity || used + len(text) >= len(app.settings_profile_edit_buffer) {
		set_settings_notice(app, "Profile field limit reached")
		return false
	}
	app.settings_profile_edit_len = used
	app.settings_profile_select_all = false
	copy(
		app.settings_profile_edit_buffer[app.settings_profile_edit_len:app.settings_profile_edit_len + len(text)],
		transmute([]u8)text,
	)
	app.settings_profile_edit_len += len(text)
	return true
}

backspace_profile_edit :: proc(app: ^App) -> bool {
	if app == nil || !app.settings_profile_editing || app.settings_profile_edit_len == 0 {
		return false
	}
	if app.settings_profile_select_all {
		app.settings_profile_edit_len = 0
		app.settings_profile_select_all = false
		return true
	}
	next := app.settings_profile_edit_len - 1
	for next > 0 && app.settings_profile_edit_buffer[next] & 0xc0 == 0x80 {
		next -= 1
	}
	app.settings_profile_edit_len = next
	return true
}

profile_env_name_conflict :: proc(profile: ^Profile, name: string, ignored_index: int) -> bool {
	if profile == nil {
		return false
	}
	for index in 0..<profile.env_count {
		if index != ignored_index && profile_env_name(&profile.env[index]) == name {
			return true
		}
	}
	return false
}

apply_profile_name_to_tabs :: proc(app: ^App, profile_index: int) {
	if app == nil {
		return
	}
	profile := profile_at(app, profile_index)
	if profile == nil {
		return
	}
	for tab_index in 0..<app.tab_count {
		if app.tabs[tab_index].profile == profile_index {
			app.tabs[tab_index].title = profile_name(profile)
		}
	}
}

commit_profile_edit :: proc(app: ^App) -> bool {
	if app == nil || !app.settings_profile_editing {
		return false
	}
	profile := selected_settings_profile(app)
	if profile == nil || profile.built_in {
		cancel_profile_edit(app)
		return false
	}
	value := string(app.settings_profile_edit_buffer[:app.settings_profile_edit_len])
	field := app.settings_profile_edit_field
	ok := false
	switch field {
	case .Name:
		if len(value) == 0 {
			set_settings_notice(app, "Profile name cannot be empty")
			return false
		}
		ok = profile_set_text(profile.name[:], &profile.name_len, value)
		if ok do apply_profile_name_to_tabs(app, app.settings_profile_selection)
	case .Shell:
		ok = profile.mode == .Launch && profile_set_text(profile.shell[:], &profile.shell_len, value)
	case .Command:
		ok = profile.mode == .Launch && profile_set_text(profile.command[:], &profile.command_len, value)
	case .Cwd:
		ok = profile.mode == .Launch && profile_set_text(profile.cwd[:], &profile.cwd_len, value)
	case .Endpoint:
		if profile.mode != .Attach || len(value) == 0 {
			set_settings_notice(app, "Attach endpoint cannot be empty")
			return false
		}
		ok = profile_set_text(profile.endpoint[:], &profile.endpoint_len, value)
	case .Env_Name:
		index := app.settings_profile_edit_env_index
		if profile.mode != .Launch || index < 0 || index >= profile.env_count ||
		   !valid_profile_env_name(value) || profile_env_name_conflict(profile, value, index) {
			set_settings_notice(app, "Environment name is invalid or duplicated")
			return false
		}
		ok = profile_set_text(profile.env[index].name[:], &profile.env[index].name_len, value)
	case .Font:
		parsed, parsed_ok := parse_profile_font_pixels(value)
		if !parsed_ok {
			set_settings_notice(app, "Font size must be blank or 8–48 px")
			return false
		}
		profile.font_pixels = parsed
		ok = true
		profile_apply_font_to_views(app, app.settings_profile_selection)
	case .Env_Value:
		index := app.settings_profile_edit_env_index
		if profile.mode != .Launch || index < 0 || index >= profile.env_count {
			return false
		}
		ok = profile_set_text(profile.env[index].value[:], &profile.env[index].value_len, value)
	case .Mode:
		return false
	}
	if !ok {
		set_settings_notice(app, "Profile field could not be saved")
		return false
	}
	cancel_profile_edit(app)
	save_user_config(app)
	set_settings_notice(app, "Saved · launch edits apply after restart")
	return true
}

adjust_profile_mode :: proc(app: ^App, delta: int) -> bool {
	profile := selected_settings_profile(app)
	if app == nil || profile == nil || profile.built_in || delta == 0 {
		return false
	}
	next := profile.mode == .Launch ? Profile_Mode.Attach : Profile_Mode.Launch
	if next == profile.mode {
		return false
	}
	profile.mode = next
	if next == .Attach {
		profile.shell_len = 0
		profile.command_len = 0
		profile.cwd_len = 0
		profile.env_count = 0
		if profile.endpoint_len == 0 {
			_ = profile_set_text(profile.endpoint[:], &profile.endpoint_len, HOME_ENDPOINT)
		}
	} else {
		profile.endpoint_len = 0
	}
	app.settings_profile_env_selection = 0
	save_user_config(app)
	set_settings_notice(app, "Profile mode saved · affects future/restarted Instances")
	return true
}

add_profile_environment :: proc(app: ^App) -> bool {
	profile := selected_settings_profile(app)
	if app == nil || profile == nil || profile.built_in || profile.mode != .Launch || profile.env_count >= MAX_PROFILE_ENV {
		return false
	}
	storage: [PROFILE_ENV_NAME_BYTES]u8
	name: string
	for identity in 1..=999 {
		candidate := fmt.bprintf(storage[:], "NEW_VAR_%d", identity)
		if !profile_env_duplicate(profile, candidate) {
			name = candidate
			break
		}
	}
	if len(name) == 0 {
		return false
	}
	entry := &profile.env[profile.env_count]
	entry^ = {}
	if !profile_set_text(entry.name[:], &entry.name_len, name) {
		return false
	}
	app.settings_profile_env_selection = profile.env_count
	profile.env_count += 1
	save_user_config(app)
	set_settings_notice(app, "Environment override added")
	return true
}

delete_profile_environment :: proc(app: ^App) -> bool {
	profile := selected_settings_profile(app)
	if app == nil || profile == nil || profile.built_in || profile.env_count == 0 {
		return false
	}
	index := clamp(app.settings_profile_env_selection, 0, profile.env_count - 1)
	for current in index..<profile.env_count - 1 {
		profile.env[current] = profile.env[current + 1]
	}
	profile.env_count -= 1
	profile.env[profile.env_count] = {}
	app.settings_profile_env_selection = clamp(index, 0, max(0, profile.env_count - 1))
	save_user_config(app)
	set_settings_notice(app, "Environment override removed")
	return true
}

handle_profile_edit_key :: proc(app: ^App, event: ^SDL.Event) -> bool {
	if app == nil || !app.settings_profile_editing {
		return false
	}
	if event.type != .KEY_DOWN {
		return true
	}
	if event.key.key == SDL.K_A && (.LCTRL in event.key.mod || .RCTRL in event.key.mod) {
		app.settings_profile_select_all = true
		return true
	}
	switch event.key.key {
	case SDL.K_ESCAPE:
		cancel_profile_edit(app)
		set_settings_notice(app, "Profile edit canceled")
	case SDL.K_RETURN:
		_ = commit_profile_edit(app)
	case SDL.K_BACKSPACE:
		_ = backspace_profile_edit(app)
	case SDL.K_END, SDL.K_RIGHT:
		app.settings_profile_select_all = false
	case SDL.K_DELETE:
		if app.settings_profile_select_all do _ = backspace_profile_edit(app)
	case:
		// TEXT_INPUT owns printable committed text while the editor is active.
	}
	return true
}

open_profile_editor :: proc(app: ^App, profile_index: int, focus_name := false) -> bool {
	if app == nil || profile_at(app, profile_index) == nil {
		return false
	}
	cancel_profile_edit(app)
	app.settings_profile_selection = profile_index
	app.settings_page = .Profile_Home
	app.settings_content_focus = true
	app.settings_profile_field = int(Profile_Edit_Field.Name)
	app.settings_profile_env_selection = 0
	app.settings_notice_len = 0
	if focus_name {
		_ = begin_profile_edit(app, .Name)
	}
	return true
}

handle_profile_list_key :: proc(app: ^App, event: ^SDL.Event) -> bool {
	if app == nil || event.type != .KEY_DOWN || app.profile_count == 0 do return false
	if event.key.key != SDL.K_DELETE && event.key.key != SDL.K_BACKSPACE do app.settings_delete_pending = false
	switch event.key.key {
	case SDL.K_TAB: app.settings_content_focus = false
	case SDL.K_UP: app.settings_profile_selection = (app.settings_profile_selection + app.profile_count - 1) % app.profile_count
	case SDL.K_DOWN: app.settings_profile_selection = (app.settings_profile_selection + 1) % app.profile_count
	case SDL.K_RETURN: _ = profile_ui_action(app, .Edit)
	case SDL.K_N: _ = profile_ui_action(app, .New)
	case SDL.K_D: _ = profile_ui_action(app, .Duplicate)
	case SDL.K_DELETE, SDL.K_BACKSPACE:
		if event.key.repeat do return true
		if !profile_ui_action(app, .Delete) {
			set_settings_notice(app, "Built-in or in-use profiles cannot be deleted")
		}
	case: return false
	}
	return true
}

handle_profile_editor_key :: proc(app: ^App, event: ^SDL.Event) -> bool {
	if app == nil || event.type != .KEY_DOWN {
		return false
	}
	profile := selected_settings_profile(app)
	if profile == nil {
		return false
	}
	field, field_ok := profile_edit_field_at(app.settings_profile_field)
	if !field_ok {
		app.settings_profile_field = 0
		field = .Name
	}
	switch event.key.key {
	case SDL.K_TAB:
		app.settings_content_focus = false
	case SDL.K_UP:
		app.settings_profile_field = (app.settings_profile_field + PROFILE_EDIT_FIELD_COUNT - 1) % PROFILE_EDIT_FIELD_COUNT
	case SDL.K_DOWN:
		app.settings_profile_field = (app.settings_profile_field + 1) % PROFILE_EDIT_FIELD_COUNT
	case SDL.K_RETURN:
		if profile.built_in {
			set_settings_notice(app, "Built-in profile · press D to duplicate")
		} else if field == .Mode {
			_ = adjust_profile_mode(app, 1)
		} else {
			_ = begin_profile_edit(app, field)
		}
	case SDL.K_LEFT:
		if field == .Mode do _ = adjust_profile_mode(app, -1)
		if (field == .Env_Name || field == .Env_Value) && profile.env_count != 0 {
			app.settings_profile_env_selection = (app.settings_profile_env_selection + profile.env_count - 1) % profile.env_count
		}
	case SDL.K_RIGHT:
		if field == .Mode do _ = adjust_profile_mode(app, 1)
		if (field == .Env_Name || field == .Env_Value) && profile.env_count != 0 {
			app.settings_profile_env_selection = (app.settings_profile_env_selection + 1) % profile.env_count
		}
	case SDL.K_N:
		if field == .Env_Name || field == .Env_Value {
			_ = add_profile_environment(app)
			return true
		}
		return false
	case SDL.K_DELETE, SDL.K_BACKSPACE:
		if field == .Env_Name || field == .Env_Value {
			_ = delete_profile_environment(app)
			return true
		}
		return false
	case SDL.K_D:
		if profile.built_in {
			_ = profile_ui_action(app, .Duplicate)
			return true
		}
		return false
	case:
		return false
	}
	return true
}

profile_editor_input_rect :: proc(app: ^App, width, height: f32) -> (SDL.FRect, bool) {
	if app == nil || !app.settings_open || app.settings_page != .Profile_Home || !app.settings_profile_editing {
		return {}, false
	}
	body := settings_layout(width, height).body
	field_index := int(app.settings_profile_edit_field)
	if field_index < 0 || field_index >= PROFILE_EDIT_FIELD_COUNT do return {}, false
	rect := settings_profile_value(settings_profile_row(body, app.settings_scroll_y, field_index, true))
	return rect, rect.y >= body.y && rect.y + rect.h <= body.y + body.h

}

profile_field_relevant :: proc(profile: ^Profile, field: Profile_Edit_Field) -> bool {
	if profile == nil {
		return false
	}
	switch field {
	case .Shell, .Command, .Cwd, .Env_Name, .Env_Value:
		return profile.mode == .Launch
	case .Endpoint:
		return profile.mode == .Attach
	case .Name, .Mode, .Font:
		return true
	}
	return false
}

draw_profiles_settings :: proc(app: ^App, body: SDL.FRect) {
	for index in 0..<app.profile_count {
		profile := app.profiles[index]
		row := settings_profile_row(body, app.settings_scroll_y, index, false)
		selected := app.settings_profile_selection == index
		draw_fill(app.renderer, row, selected ? palette.tab_active : palette.title_bg)
		draw_outline(app.renderer, row, selected ? palette.accent : palette.border)
		settings_clipped_text(app, {row.x + 10, row.y + 3, max(f32(0), row.w - 94), 20}, profile_name(profile), palette.text)
		kind := profile.built_in ? "Template" : "Custom"
		mode := profile.mode == .Launch ? "Owned instance" : "Attach only"
		detail_storage: [96]u8
		detail := fmt.bprintf(detail_storage[:], "%s · %s%s", kind, mode, app.startup_profile == index ? " · Default" : "")
		settings_clipped_text(app, {row.x + 10, row.y + 22, max(f32(0), row.w - 94), 18}, detail, palette.text_muted)
		settings_draw_button(app, {row.x + row.w - 74, row.y + 4, 66, 32}, profile.built_in ? "View" : "Edit")
	}
}

draw_profile_editor_settings :: proc(app: ^App, body: SDL.FRect) {
	profile := selected_settings_profile(app)
	if profile == nil do return
	for field_index in 0..<PROFILE_EDIT_FIELD_COUNT {
		field, _ := profile_edit_field_at(field_index)
		row := settings_profile_row(body, app.settings_scroll_y, field_index, true)
		selected := app.settings_content_focus && app.settings_profile_field == field_index
		if selected do draw_fill(app.renderer, row, palette.tab_active)
		label_storage: [96]u8
		label := profile_field_label(field, app.settings_profile_env_selection, profile.env_count, label_storage[:])
		relevant := profile_field_relevant(profile, field)
		rect := settings_profile_value(row)
		settings_clipped_text(app, {row.x + 10, row.y + 13, max(f32(0), rect.x - row.x - 18), 22}, label, relevant ? palette.text_muted : palette.border)
		value_storage: [96]u8
		value := profile_field_value(profile, field, app.settings_profile_env_selection, value_storage[:])
		if !profile.built_in && field == .Mode {
			settings_draw_stepper(app, rect, value, true, true, false)
			continue
		}
		editable := profile_text_field_editable(profile, field)
		editing := app.settings_profile_editing && app.settings_profile_edit_field == field
		if editable {
			draw_fill(app.renderer, rect, editing && app.settings_profile_select_all ? palette.tab_active : palette.terminal_bg)
			draw_outline(app.renderer, rect, editing ? palette.accent : palette.border)
		}
		if editing do value = string(app.settings_profile_edit_buffer[:app.settings_profile_edit_len])
		settings_clipped_text(app, {rect.x + 7, rect.y + 8, max(f32(0), rect.w - 14), rect.h - 8}, value,
							  editable ? palette.text : palette.text_muted)
	}
}
