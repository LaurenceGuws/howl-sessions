package main

import "core:testing"
import SDL "vendor:sdl3"

@(test)
all_mapping_defaults_parse_roundtrip_and_reserve_no_alt :: proc(t: ^testing.T) {
	for definition in KEY_MAPPING_DEFINITIONS {
		if len(definition.default_shortcut) == 0 do continue
		shortcut, ok := parse_shortcut(definition.default_shortcut)
		testing.expect(t, ok)
		testing.expect(t, shortcut.modifiers & SHORTCUT_MOD_ALT == 0)
		buffer: [SHORTCUT_TEXT_BYTES]u8
		formatted, formatted_ok := format_shortcut(shortcut, buffer[:])
		testing.expect(t, formatted_ok)
		testing.expect_value(t, formatted, definition.default_shortcut)
	}
}

@(test)
shortcut_parser_rejects_ambiguous_or_modifier_only_chords :: proc(t: ^testing.T) {
	cases := [6]string{"", "Ctrl", "Ctrl+", "Ctrl+Ctrl+T", "Ctrl+T+N", "Nope+T"}
	for text in cases {
		_, ok := parse_shortcut(text)
		testing.expect(t, !ok)
	}
}

@(test)
shortcut_event_matching_ignores_lock_state_and_rejects_repeat :: proc(t: ^testing.T) {
	shortcut, ok := parse_shortcut("Ctrl+Shift+P")
	testing.expect(t, ok)
	event := SDL.Event{}
	event.type = .KEY_DOWN
	event.key.key = SDL.K_P
	event.key.mod = {.LCTRL, .RSHIFT, .CAPS, .NUM}
	testing.expect(t, shortcut_matches_event(shortcut, &event))
	event.key.repeat = true
	testing.expect(t, !shortcut_matches_event(shortcut, &event))
}

@(test)
shortcut_parser_supports_punctuation_navigation_and_functions :: proc(t: ^testing.T) {
	cases := [6]string{"Ctrl+,", "Alt+Shift+-", "Ctrl+Plus", "Alt+Left", "F12", "Super+Space"}
	for text in cases {
		shortcut, ok := parse_shortcut(text)
		testing.expect(t, ok)
		buffer: [SHORTCUT_TEXT_BYTES]u8
		formatted, formatted_ok := format_shortcut(shortcut, buffer[:])
		testing.expect(t, formatted_ok)
		testing.expect_value(t, formatted, text)
	}
}

@(test)
effective_bindings_reject_conflicts_transactionally :: proc(t: ^testing.T) {
	app: App
	testing.expect(t, initialize_key_mappings(&app))
	before := action_binding_text(&app, .New_Window)
	result := set_action_binding(&app, .New_Window, "Ctrl+T")
	testing.expect_value(t, result, Binding_Update_Result.Conflict)
	testing.expect_value(t, action_binding_text(&app, .New_Window), before)
	testing.expect_value(t, action_binding_text(&app, .New_Tab), "Ctrl+T")
}

@(test)
effective_bindings_apply_unbind_and_reset :: proc(t: ^testing.T) {
	app: App
	testing.expect(t, initialize_key_mappings(&app))
	testing.expect_value(t, set_action_binding(&app, .New_Window, "Super+N"), Binding_Update_Result.Applied)
	testing.expect_value(t, action_binding_text(&app, .New_Window), "Super+N")
	testing.expect_value(t, set_action_binding(&app, .New_Window, ""), Binding_Update_Result.Applied)
	testing.expect_value(t, action_binding_text(&app, .New_Window), "")
	testing.expect(t, reset_action_binding(&app, .New_Window))
	testing.expect_value(t, action_binding_text(&app, .New_Window), "Ctrl+Shift+N")
}

@(test)
registered_shortcut_lookup_uses_effective_binding :: proc(t: ^testing.T) {
	app: App
	testing.expect(t, initialize_key_mappings(&app))
	testing.expect_value(t, set_action_binding(&app, .New_Window, "Super+N"), Binding_Update_Result.Applied)
	event := SDL.Event{}
	event.type = .KEY_DOWN
	event.key.key = SDL.K_N
	event.key.mod = {.LGUI}
	action, ok := action_for_shortcut_event(&app, &event)
	testing.expect(t, ok)
	testing.expect_value(t, action, App_Action.New_Window)
}

@(test)
shortcut_recording_ignores_modifier_only_and_captures_final_key :: proc(t: ^testing.T) {
	event := SDL.Event{}
	event.type = .KEY_DOWN
	event.key.key = SDL.K_LCTRL
	event.key.mod = {.LCTRL}
	_, ok := shortcut_from_key_event(&event)
	testing.expect(t, !ok)

	event.key.key = SDL.K_K
	event.key.mod = {.LCTRL, .LSHIFT}
	shortcut, captured := shortcut_from_key_event(&event)
	testing.expect(t, captured)
	buffer: [SHORTCUT_TEXT_BYTES]u8
	formatted, formatted_ok := format_shortcut(shortcut, buffer[:])
	testing.expect(t, formatted_ok)
	testing.expect_value(t, formatted, "Ctrl+Shift+K")
}

@(test)
config_binding_overrides_are_transactional_and_allow_swaps :: proc(t: ^testing.T) {
	app: App
	testing.expect(t, initialize_key_mappings(&app))
	overrides := [2]User_Key_Mapping_Config{
		{action = "new_tab", shortcut = "Ctrl+Shift+N"},
		{action = "new_window", shortcut = "Ctrl+T"},
	}
	testing.expect(t, apply_user_keybindings(&app, overrides[:]))
	testing.expect_value(t, action_binding_text(&app, .New_Tab), "Ctrl+Shift+N")
	testing.expect_value(t, action_binding_text(&app, .New_Window), "Ctrl+T")
}

@(test)
invalid_config_binding_set_preserves_defaults_and_names_bad_field :: proc(t: ^testing.T) {
	app: App
	testing.expect(t, initialize_key_mappings(&app))
	overrides := [1]User_Key_Mapping_Config{{action = "new_window", shortcut = "Ctrl+Ctrl+N"}}
	testing.expect(t, !apply_user_keybindings(&app, overrides[:]))
	testing.expect_value(t, action_binding_text(&app, .New_Window), "Ctrl+Shift+N")
	testing.expect(t, app.config_notice_len != 0)
	notice := string(app.config_notice[:app.config_notice_len])
	testing.expect(t, len(notice) >= len("keybindings[0]") && notice[:len("keybindings[0]")] == "keybindings[0]")
}

@(test)
mapping_registry_has_unique_ids_and_complete_parameterized_inventory :: proc(t: ^testing.T) {
	count_action, count_find, count_tab, count_font := 0, 0, 0, 0
	count_copy, count_paste := 0, 0
	count_oldest, count_live, count_page := 0, 0, 0
	count_focus, count_resize, count_swap := 0, 0, 0

	for definition, index in KEY_MAPPING_DEFINITIONS {
		id := mapping_id(definition)
		testing.expect(t, len(id) != 0)
		testing.expect(t, len(mapping_label(definition)) != 0)
		for other, other_index in KEY_MAPPING_DEFINITIONS {
			if other_index > index do testing.expect(t, mapping_id(other) != id)
		}
		switch definition.target.kind {
		case .Action:          count_action += 1
		case .Toggle_Find:     count_find += 1
		case .Select_Tab:      count_tab += 1
		case .Adjust_Font:     count_font += 1
		case .Copy_Selection:  count_copy += 1
		case .Paste_Clipboard: count_paste += 1
		case .History_Oldest:  count_oldest += 1
		case .History_Live:    count_live += 1
		case .History_Page:    count_page += 1
		case .Pane_Focus:      count_focus += 1
		case .Pane_Resize:     count_resize += 1
		case .Pane_Swap:       count_swap += 1
		}
	}

	testing.expect_value(t, count_action, len(ACTION_DEFINITIONS))
	testing.expect_value(t, count_find, 1)
	testing.expect_value(t, count_tab, MAX_TABS)
	testing.expect_value(t, count_font, 2)
	testing.expect_value(t, count_copy, 1)
	testing.expect_value(t, count_paste, 1)
	testing.expect_value(t, count_oldest, 1)
	testing.expect_value(t, count_live, 1)
	testing.expect_value(t, count_page, 2)
	testing.expect_value(t, count_focus, 4)
	testing.expect_value(t, count_resize, 4)
	testing.expect_value(t, count_swap, 4)
}

@(test)
parameterized_mapping_rebinds_through_same_config_path :: proc(t: ^testing.T) {
	app: App
	testing.expect(t, initialize_key_mappings(&app))
	index, found := mapping_index_from_id("select_tab_3")
	testing.expect(t, found)
	testing.expect_value(t, mapping_binding_text(&app, index), "Ctrl+3")

	override := [1]User_Key_Mapping_Config{{action = "select_tab_3", shortcut = "Super+3"}}
	testing.expect(t, apply_user_keybindings(&app, override[:]))
	testing.expect_value(t, mapping_binding_text(&app, index), "Super+3")

	event := SDL.Event{}
	event.type = .KEY_DOWN
	event.key.key = SDL.K_3
	event.key.mod = {.LGUI}
	resolved, ok := mapping_for_shortcut_event(&app, &event)
	testing.expect(t, ok)
	testing.expect_value(t, resolved, index)
}
