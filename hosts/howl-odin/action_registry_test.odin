package main

import "core:testing"

@(test)
action_registry_has_unique_complete_metadata :: proc(t: ^testing.T) {
    testing.expect_value(t, len(ACTION_DEFINITIONS), 21)
    for definition, index in ACTION_DEFINITIONS {
        testing.expect(t, len(definition.id) != 0)
        testing.expect(t, len(definition.label) != 0)
        found, ok := action_definition(definition.action)
        testing.expect(t, ok)
        testing.expect_value(t, found.label, definition.label)
        for other, other_index in ACTION_DEFINITIONS {
            if other_index > index {
                testing.expect(t, other.action != definition.action)
                testing.expect(t, other.id != definition.id)
            }
        }
    }
}

@(test)
palette_actions_resolve_only_through_registry :: proc(t: ^testing.T) {
    for action, index in PALETTE_ACTIONS {
        resolved, ok := palette_action(index)
        testing.expect(t, ok)
        testing.expect_value(t, resolved, action)
        _, defined := action_definition(action)
        testing.expect(t, defined)
    }
    _, ok := palette_action(-1)
    testing.expect(t, !ok)
    _, ok = palette_action(len(PALETTE_ACTIONS))
    testing.expect(t, !ok)
}

@(test)
action_context_disables_only_impossible_operations :: proc(t: ^testing.T) {
    app: App
    testing.expect(t, action_enabled(&app, .New_Tab))
    testing.expect(t, action_enabled(&app, .New_Window))
    testing.expect(t, !action_enabled(&app, .Close_Pane))
    testing.expect(t, !action_enabled(&app, .Split_Vertical))
    testing.expect(t, !action_enabled(&app, .Toggle_Pane_Zoom))

    app.tab_count = 1
    app.active_tab = 0
    app.tabs[0].pane_count = 1
    testing.expect(t, action_enabled(&app, .Close_Pane))
    testing.expect(t, action_enabled(&app, .Split_Vertical))
    testing.expect(t, !action_enabled(&app, .Toggle_Pane_Zoom))

    app.tabs[0].pane_count = 2
    testing.expect(t, action_enabled(&app, .Toggle_Pane_Zoom))
    app.tabs[0].pane_count = MAX_PANES_PER_TAB
    testing.expect(t, !action_enabled(&app, .Split_Horizontal))
}

@(test)
registry_owns_visible_default_shortcuts :: proc(t: ^testing.T) {
    testing.expect_value(t, action_default_shortcut(.New_Tab), "Ctrl+T")
    testing.expect_value(t, action_default_shortcut(.New_Window), "Ctrl+Shift+N")
    testing.expect_value(t, action_default_shortcut(.Split_Horizontal), "")
    testing.expect_value(t, action_default_shortcut(.Open_Command_Palette), "Ctrl+Shift+P")
    testing.expect_value(t, action_default_shortcut(.Close_Pane), "Ctrl+Shift+W")
}


@(test)
action_ids_roundtrip_without_enum_position :: proc(t: ^testing.T) {
    for definition in ACTION_DEFINITIONS {
        action, ok := action_from_id(definition.id)
        testing.expect(t, ok)
        testing.expect_value(t, action, definition.action)
    }
    _, ok := action_from_id("not_an_action")
    testing.expect(t, !ok)
}
