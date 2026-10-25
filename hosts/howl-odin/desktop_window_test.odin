package main

import "core:testing"
import SDL "vendor:sdl3"

@(test)
window_presentation_sleeps_only_when_hidden_or_minimized :: proc(t: ^testing.T) {
    testing.expect(t, window_presentation_allowed({}))
    testing.expect(t, window_presentation_allowed({.FULLSCREEN, .INPUT_FOCUS}))
    testing.expect(t, window_presentation_allowed({.MAXIMIZED}))
    testing.expect(t, !window_presentation_allowed({.MINIMIZED}))
    testing.expect(t, !window_presentation_allowed({.HIDDEN}))
    testing.expect(t, !window_presentation_allowed({.FULLSCREEN, .MINIMIZED}))
}

@(test)
fullscreen_is_a_rebindable_window_action :: proc(t: ^testing.T) {
    app: App
    testing.expect(t, initialize_key_mappings(&app))
    testing.expect_value(t, action_default_shortcut(.Toggle_Fullscreen), "F11")
    testing.expect(t, !action_enabled(&app, .Toggle_Fullscreen))
    testing.expect_value(t, set_action_binding(&app, .Toggle_Fullscreen, "Ctrl+F11"), Binding_Update_Result.Applied)
}

@(test)
action_key_ownership_covers_repeat_and_release_after_modifier_change :: proc(t: ^testing.T) {
    app: App
    app.mapping_keys_owned[87] = true
    repeat: SDL.Event
    repeat.type = .KEY_DOWN
    repeat.key.scancode = SDL.Scancode(87)
    repeat.key.repeat = true
    testing.expect(t, consume_owned_mapping_key(&app, &repeat))
    release := repeat
    release.type = .KEY_UP
    release.key.mod = {}
    testing.expect(t, consume_owned_mapping_key(&app, &release))
    testing.expect(t, !consume_owned_mapping_key(&app, &release))
    testing.expect(t, !consume_owned_mapping_key(&app, &repeat))
}

@(test)
action_key_new_press_recovers_from_missing_release :: proc(t: ^testing.T) {
    app: App
    app.mapping_keys_owned[87] = true
    press: SDL.Event
    press.type = .KEY_DOWN
    press.key.scancode = SDL.Scancode(87)
    testing.expect(t, !consume_owned_mapping_key(&app, &press))
    testing.expect(t, !app.mapping_keys_owned[87])
    press.key.scancode = SDL.Scancode(0)
    testing.expect(t, !consume_owned_mapping_key(&app, &press))
    testing.expect(t, !consume_owned_mapping_key(nil, &press))
    testing.expect(t, !consume_owned_mapping_key(&app, nil))
}

@(test)
registered_action_claims_its_physical_key_even_when_disabled :: proc(t: ^testing.T) {
    app: App
    testing.expect(t, initialize_key_mappings(&app))
    event: SDL.Event
    event.type = .KEY_DOWN
    event.key.key = SDL.K_F11
    event.key.scancode = SDL.Scancode(87)
    testing.expect(t, handle_registered_mapping(&app, &event))
    testing.expect(t, app.mapping_keys_owned[87])
    event.type = .KEY_UP
    testing.expect(t, consume_owned_mapping_key(&app, &event))
    testing.expect(t, !app.mapping_keys_owned[87])
}
