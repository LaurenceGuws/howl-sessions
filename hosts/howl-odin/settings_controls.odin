package main

import "core:c"
import "core:math"
import SDL "vendor:sdl3"

// Settings-only layout and controls. Painting and hit testing share these
// rectangles; no retained widget tree, timer, or terminal policy lives here.
Settings_Layout :: struct {
    panel, body, toolbar, footer: SDL.FRect,
}

settings_layout :: proc(width, height: f32) -> Settings_Layout {
    panel := settings_panel_rect(width, height)
    x := panel.x + 194
    w := max(f32(0), panel.w - 210)
    body := SDL.FRect{x, panel.y + 92, w, max(f32(0), panel.h - 198)}
    return {panel, body, {x, panel.y + 48, w, 32}, {x, body.y + body.h + 10, w, 86}}
}

settings_sidebar_row :: proc(panel: SDL.FRect, index: int) -> SDL.FRect {
    return {panel.x + 8, panel.y + 52 + f32(index) * 34, 162, 30}
}

settings_button_rect :: proc(row: SDL.FRect, index, count: int) -> SDL.FRect {
    if count <= 0 || index < 0 || index >= count do return {}
    w := max(f32(0), (row.w - f32(count - 1) * 6) / f32(count))
    return {row.x + f32(index) * (w + 6), row.y, w, row.h}
}

settings_clipped_text :: proc(app: ^App, rect: SDL.FRect, text: string, color: SDL.Color) {
    if rect.w <= 0 || rect.h <= 0 do return
    had_clip := SDL.RenderClipEnabled(app.renderer)
    previous: SDL.Rect
    _ = SDL.GetRenderClipRect(app.renderer, &previous)
    clip := SDL.Rect{c.int(math.ceil(rect.x)), c.int(math.ceil(rect.y)), c.int(rect.w), c.int(rect.h)}
    if had_clip && !SDL.GetRectIntersection(clip, previous, &clip) do return
    _ = SDL.SetRenderClipRect(app.renderer, &clip)
    draw_text(app, app.ui_font, text, rect.x, rect.y, color)
    if had_clip {
        _ = SDL.SetRenderClipRect(app.renderer, &previous)
    } else {
        _ = SDL.SetRenderClipRect(app.renderer, nil)
    }
}

settings_draw_button :: proc(app: ^App, rect: SDL.FRect, label: string, enabled := true, selected := false) {
    draw_fill(app.renderer, rect, enabled ? palette.tab_idle : palette.title_bg)
    draw_outline(app.renderer, rect, selected ? palette.accent : palette.border)
    x := rect.x + max(f32(6), (rect.w - text_width(app, app.ui_font, label)) / 2)
    settings_clipped_text(app, {x, rect.y + 7, max(f32(0), rect.x + rect.w - 6 - x), rect.h - 8}, label,
                          enabled ? (selected ? palette.accent : palette.text) : palette.text_muted)
}

settings_profile_row :: proc(body: SDL.FRect, scroll: f32, index: int, editor: bool) -> SDL.FRect {
    step := editor ? f32(48) : f32(44)
    return {body.x, body.y + f32(index) * step - scroll, max(f32(0), body.w - 8), step - 4}
}

settings_profile_value :: proc(row: SDL.FRect) -> SDL.FRect {
    label_width := min(f32(174), row.w * 0.46)
    return {row.x + label_width, row.y + 5, max(f32(0), row.w - label_width - 8), row.h - 10}
}

settings_choice_rect :: proc(body: SDL.FRect, scroll, offset: f32) -> SDL.FRect {
    return {body.x + 8, body.y + offset + 24 - scroll, max(f32(0), body.w - 16), 38}
}

settings_stepper_parts :: proc(rect: SDL.FRect) -> (left, value, right: SDL.FRect) {
    button := min(f32(36), rect.w / 3)
    return {rect.x, rect.y, button, rect.h},
           {rect.x + button + 4, rect.y, max(f32(0), rect.w - button * 2 - 8), rect.h},
           {rect.x + rect.w - button, rect.y, button, rect.h}
}

settings_stepper_hit :: proc(rect: SDL.FRect, x, y: f32) -> int {
    left, _, right := settings_stepper_parts(rect)
    if inside(x, y, left) do return -1
    if inside(x, y, right) do return 1
    return 0
}

settings_draw_stepper :: proc(app: ^App, rect: SDL.FRect, label: string, previous, next: bool, numeric := false) {
    left, value, right := settings_stepper_parts(rect)
    settings_draw_button(app, left, numeric ? "-" : "<", previous)
    settings_draw_button(app, right, numeric ? "+" : ">", next)
    draw_fill(app.renderer, value, palette.terminal_bg)
    settings_clipped_text(app, {value.x + 8, value.y + 8, max(f32(0), value.w - 16), value.h - 8}, label, palette.text)
}

settings_content_height :: proc(app: ^App) -> f32 {
    switch app.settings_page {
    case .Profile_Defaults: return f32(app.profile_count) * 44
    case .Profile_Home:     return f32(PROFILE_EDIT_FIELD_COUNT) * 48
    case .Mappings:          return f32(len(KEY_MAPPING_DEFINITIONS)) * 32 + 12
    case .Appearance:       return 500
    case .Startup, .Interaction: return 270
    case .Color_Schemes:    return 260
    }
    return 0
}

settings_sync_scroll :: proc(app: ^App, body: SDL.FRect) -> f32 {
    if app.settings_scroll_page != app.settings_page {
        app.settings_scroll_y = 0
        app.settings_scroll_page = app.settings_page
    }
    limit := max(f32(0), settings_content_height(app) - body.h)
    app.settings_scroll_y = clamp(app.settings_scroll_y, 0, limit)
    return limit
}

settings_reveal_range :: proc(scroll, top, size, viewport, limit: f32) -> f32 {
    result := scroll
    if top < result {
        result = top
    } else if top + size > result + viewport {
        result = top + size - viewport
    }
    return clamp(result, 0, limit)
}

settings_reveal_selection :: proc(app: ^App) {
    if app == nil || app.window == nil || !app.settings_open || !app.settings_content_focus do return
    w, h: c.int
    if !SDL.GetWindowSize(app.window, &w, &h) do return
    layout := settings_layout(f32(w), f32(h))
    limit := settings_sync_scroll(app, layout.body)
    top, size: f32
    switch app.settings_page {
    case .Profile_Defaults: top, size = f32(app.settings_profile_selection) * 44, 40
    case .Profile_Home: top, size = f32(app.settings_profile_field) * 48, 44
    case .Mappings: top, size = f32(app.settings_mapping_selection) * 32 + 2, 30
    case .Appearance:
        if app.settings_font_field == 0 {
            top, size = 82, 44
        } else {
            top, size = 142 + f32(app.settings_font_field - 1) * 48, 44
        }
    case .Startup, .Interaction, .Color_Schemes: return
    }
    app.settings_scroll_y = settings_reveal_range(app.settings_scroll_y, top, size, layout.body.h, limit)
}

settings_footer_note :: proc(app: ^App) -> string {
    if app.settings_notice_len != 0 do return string(app.settings_notice[:app.settings_notice_len])
    if app.config_notice_len != 0 do return string(app.config_notice[:app.config_notice_len])
    if app.settings_profile_editing || app.settings_font_editing do return "Enter saves; Esc cancels; Ctrl+A selects all."
    switch app.settings_page {
    case .Profile_Defaults: return "Select a profile, then Edit or Duplicate."
    case .Profile_Home:
        profile := selected_settings_profile(app)
        if profile != nil && profile.built_in do return "Read-only template. Duplicate to customize."
        return "Click a field to edit. Launch changes apply next time."
    case .Appearance: return "Blank paths inherit startup fonts; blank styles use a custom regular face when one is set."
    case .Startup: return "Used for new windows, tabs, and split panes."
    case .Color_Schemes: return "Application chrome only; terminal colors are unchanged."
    case .Mappings: return "Every global shortcut is listed here. Enter records; Del unbinds; R resets."
    case .Interaction: return "Terminal behavior belongs to the canonical Instance."
    }
    return ""
}

Profile_UI_Action :: enum { New, Duplicate, Edit, Delete, Default, Back, Save, Cancel }

profile_ui_action_enabled :: proc(app: ^App, action: Profile_UI_Action) -> bool {
    if app == nil do return false
    if app.settings_profile_editing do return action == .Save || action == .Cancel
    profile := selected_settings_profile(app)
    switch action {
    case .New: return app.profile_count < MAX_PROFILES
    case .Duplicate: return profile != nil && app.profile_count < MAX_PROFILES
    case .Edit: return profile != nil
    case .Delete: return profile != nil && !profile.built_in && !profile_in_use(app, app.settings_profile_selection)
    case .Default: return profile != nil && app.startup_profile != app.settings_profile_selection
    case .Back: return true
    case .Save, .Cancel: return false
    }
    return false
}

profile_ui_action :: proc(app: ^App, action: Profile_UI_Action) -> bool {
    if !profile_ui_action_enabled(app, action) do return false
    if action != .Delete do app.settings_delete_pending = false
    switch action {
    case .New, .Duplicate:
        index := action == .New ? create_user_profile(app) : duplicate_user_profile(app, app.settings_profile_selection)
        if index < 0 {
            set_settings_notice(app, "Profile could not be created")
            return false
        }
        save_user_config(app)
        app.settings_scroll_y = 0
        return open_profile_editor(app, index, true)
    case .Edit: return open_profile_editor(app, app.settings_profile_selection)
    case .Delete:
        if !app.settings_delete_pending || app.settings_delete_profile != app.settings_profile_selection {
            app.settings_delete_pending = true
            app.settings_delete_profile = app.settings_profile_selection
            set_settings_notice(app, "Press Delete again to confirm this profile's removal")
            return true
        }
        selected := app.settings_profile_selection
        app.settings_delete_pending = false
        if !delete_user_profile(app, selected) do return false
        app.settings_profile_selection = clamp(selected, 0, app.profile_count - 1)
        save_user_config(app)
        set_settings_notice(app, "Profile deleted")
    case .Default:
        app.startup_profile = app.settings_profile_selection
        save_user_config(app)
        set_settings_notice(app, "Default profile saved")
    case .Back:
        app.settings_page = .Profile_Defaults
        app.settings_content_focus = true
        app.settings_notice_len = 0
    case .Save: return commit_profile_edit(app)
    case .Cancel:
        cancel_profile_edit(app)
        set_settings_notice(app, "Edit canceled")
    }
    return true
}

settings_profile_toolbar :: proc(app: ^App) -> (actions: [3]Profile_UI_Action, labels: [3]string, count: int) {
    if app.settings_profile_editing do return {.Save, .Cancel, .Back}, {"Save", "Cancel", ""}, 2
    if app.settings_page == .Profile_Defaults {
        confirm := app.settings_delete_pending && app.settings_delete_profile == app.settings_profile_selection
        return {.New, .Duplicate, .Delete}, {"New profile", "Duplicate", confirm ? "Delete?" : "Delete"}, 3
    }
    return {.Back, .Duplicate, .Default}, {"< Profiles", "Duplicate", "Set default"}, 3
}

settings_draw_profile_toolbar :: proc(app: ^App, layout: Settings_Layout) {
    actions, labels, count := settings_profile_toolbar(app)
    for index in 0..<count {
        settings_draw_button(app, settings_button_rect(layout.toolbar, index, count), labels[index],
                             profile_ui_action_enabled(app, actions[index]))
    }
}

// Returns true only for a Settings-owned pointer action. Unsupported/read-only
// fields stay read-only, and an unsaved field is never discarded by another click.
settings_control_click :: proc(app: ^App, x, y, width, height: f32) -> bool {
    if app == nil || !app.settings_open do return false
    layout := settings_layout(width, height)
    if !inside(x, y, layout.panel) {
        return app.settings_profile_editing
    }
    limit := settings_sync_scroll(app, layout.body)
    profile_page := app.settings_page == .Profile_Defaults || app.settings_page == .Profile_Home
    if profile_page {
        actions, _, count := settings_profile_toolbar(app)
        for index in 0..<count {
            if inside(x, y, settings_button_rect(layout.toolbar, index, count)) {
                _ = profile_ui_action(app, actions[index])
                settings_reveal_selection(app)
                return true
            }
        }
    }
    if app.settings_profile_editing || app.settings_font_editing {
        set_settings_notice(app, "Save or Cancel the current field before leaving it")
        return true
    }
    close := SDL.FRect{layout.panel.x + layout.panel.w - 76, layout.panel.y + 10, 64, 30}
    if inside(x, y, close) {
        app.settings_open = false
        return true
    }
    if app.settings_page == .Profile_Defaults {
        button := SDL.FRect{layout.footer.x, layout.footer.y, 136, 30}
        if inside(x, y, button) {
            _ = profile_ui_action(app, .Default)
            return true
        }
    }
    if app.settings_page == .Profile_Home {
        profile := selected_settings_profile(app)
        if profile != nil && !profile.built_in && profile.mode == .Launch {
            labels := [4]string{"Add variable", "Remove", "<", ">"}
            for _, index in labels {
                if inside(x, y, settings_button_rect({layout.footer.x, layout.footer.y, layout.footer.w, 30}, index, 4)) {
                    switch index {
                    case 0:
                        if add_profile_environment(app) {
                            app.settings_profile_field = int(Profile_Edit_Field.Env_Name)
                            app.settings_content_focus = true
                            _ = begin_profile_edit(app, .Env_Name)
                            settings_reveal_selection(app)
                        }
                    case 1: _ = delete_profile_environment(app)
                    case 2: app.settings_profile_env_selection = max(0, app.settings_profile_env_selection - 1)
                    case 3: app.settings_profile_env_selection = min(max(0, profile.env_count - 1), app.settings_profile_env_selection + 1)
                    }
                    return true
                }
            }
        }
    }
    if !inside(x, y, layout.body) do return false
    // A narrow scrollbar click seeks without conflating profile fields with it.
    if limit > 0 && x >= layout.body.x + layout.body.w - 7 {
        app.settings_scroll_y = clamp((y - layout.body.y) / max(f32(1), layout.body.h), 0, 1) * limit
        return true
    }
    offset := app.settings_scroll_y
    switch app.settings_page {
    case .Startup:
        if delta := settings_stepper_hit(settings_choice_rect(layout.body, offset, 0), x, y); delta != 0 {
            adjust_startup_profile(app, delta)
            return true
        }
    case .Appearance:
        if delta := settings_stepper_hit(settings_choice_rect(layout.body, offset, 0), x, y); delta != 0 {
            adjust_default_terminal_font(app, delta)
            return true
        }
        family_row := font_family_choice_row(layout.body, offset)
        if inside(x, y, family_row) {
            app.settings_font_field = 0
            app.settings_content_focus = true
            if inside(x, y, settings_profile_value(family_row)) do _ = open_font_chooser(app)
            settings_reveal_selection(app)
            return true
        }
        for index in 0..<FONT_EDIT_FIELD_COUNT {
            row := font_settings_row(layout.body, offset, index)
            if !inside(x, y, row) do continue
            app.settings_font_field = index + 1
            app.settings_content_focus = true
            value := font_settings_value(row)
            if inside(x, y, value) {
                field, _ := font_edit_field_at(index)
                _ = begin_font_edit(app, field)
            }
            settings_reveal_selection(app)
            return true
        }
    case .Color_Schemes:
        if delta := settings_stepper_hit(settings_choice_rect(layout.body, offset, 0), x, y); delta != 0 {
            _ = adjust_app_theme(app, delta)
            return true
        }
    case .Profile_Defaults:
        for index in 0..<app.profile_count {
            row := settings_profile_row(layout.body, offset, index, false)
            if inside(x, y, row) {
                app.settings_profile_selection = index
                app.settings_content_focus = true
                app.settings_delete_pending = false
                app.settings_notice_len = 0
                if x >= row.x + row.w - 74 do _ = profile_ui_action(app, .Edit)
                return true
            }
        }
    case .Profile_Home:
        profile := selected_settings_profile(app)
        if profile == nil do return true
        for index in 0..<PROFILE_EDIT_FIELD_COUNT {
            row := settings_profile_row(layout.body, offset, index, true)
            if !inside(x, y, row) do continue
            app.settings_profile_field = index
            app.settings_content_focus = true
            field, _ := profile_edit_field_at(index)
            value := settings_profile_value(row)
            if profile.built_in {
                set_settings_notice(app, "Read-only template. Use Duplicate to customize")
            } else if field == .Mode {
                if delta := settings_stepper_hit(value, x, y); delta != 0 {
                    _ = adjust_profile_mode(app, delta)
                }
            } else if inside(x, y, value) {
                _ = begin_profile_edit(app, field)
            }
            settings_reveal_selection(app)
            return true
        }
    case .Mappings:
        for _, index in KEY_MAPPING_DEFINITIONS {
            row := SDL.FRect{layout.body.x, layout.body.y + 1 + f32(index) * 32 - offset, layout.body.w - 8, 30}
            if inside(x, y, row) {
                app.settings_mapping_selection = index
                app.settings_content_focus = true
                app.settings_binding_recording = true
                set_settings_notice(app, "Press shortcut; Esc cancels")
                return true
            }
        }
    case .Interaction:
    }
    return true
}

settings_draw_note :: proc(app: ^App, rect: SDL.FRect, text: string) {
    remaining := text
    y := rect.y
    for len(remaining) != 0 && y + 18 <= rect.y + rect.h {
        end := len(remaining)
        if text_width(app, app.ui_font, remaining) > rect.w {
            end = 0
            last_space := 0
            for scalar, index in remaining {
                if index == 0 do continue
                if text_width(app, app.ui_font, remaining[:index]) > rect.w do break
                end = index
                if scalar == ' ' do last_space = index
            }
            if last_space > 0 do end = last_space
            if end == 0 do return
        }
        settings_clipped_text(app, {rect.x, y, rect.w, 19}, remaining[:end], palette.text_muted)
        remaining = remaining[end:]
        for len(remaining) > 0 && remaining[0] == ' ' do remaining = remaining[1:]
        y += 19
    }
}
