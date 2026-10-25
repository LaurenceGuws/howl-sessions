package main

import "core:testing"
import SDL "vendor:sdl3"

@(test)
pane_tree_nests_layout_without_moving_instance_slots :: proc(t: ^testing.T) {
    tab: Tab
    first_view := new(Instance_View)
    second_view := new(Instance_View)
    third_view := new(Instance_View)
    testing.expect(t, first_view != nil && second_view != nil && third_view != nil)
    if first_view == nil || second_view == nil || third_view == nil do return
    defer free(first_view)
    defer free(second_view)
    defer free(third_view)

    tab.root = new_pane_leaf(0)
    testing.expect(t, tab.root != nil)
    if tab.root == nil do return
    defer destroy_pane_nodes(tab.root)
    tab.panes[0] = first_view
    tab.pane_count = 1
    tab.active_pane = 0

    second_index, ok := split_pane_slot(&tab, 0, second_view, .Vertical)
    testing.expect(t, ok)
    testing.expect_value(t, second_index, 1)
    third_index: int
    third_index, ok = split_pane_slot(&tab, second_index, third_view, .Horizontal)
    testing.expect(t, ok)
    testing.expect_value(t, third_index, 2)
    testing.expect_value(t, tab.pane_count, 3)
    testing.expect(t, tab.panes[0] == first_view)
    testing.expect(t, tab.panes[1] == second_view)
    testing.expect(t, tab.panes[2] == third_view)

    layout := pane_layout(&tab, SDL.FRect{0, 0, 1000, 600})
    testing.expect_value(t, layout.entry_count, 3)
    testing.expect_value(t, layout.divider_count, 2)
    left, left_ok := pane_rect_from_layout(&layout, 0)
    upper_right, upper_ok := pane_rect_from_layout(&layout, 1)
    lower_right, lower_ok := pane_rect_from_layout(&layout, 2)
    testing.expect(t, left_ok && upper_ok && lower_ok)
    testing.expect(t, abs(left.w - upper_right.w) < 0.01)
    testing.expect(t, upper_right.x > left.x + left.w)
    testing.expect(t, upper_right.h < left.h)
    testing.expect(t, lower_right.y > upper_right.y + upper_right.h)
}

@(test)
pane_tree_close_promotes_sibling_subtree_and_keeps_survivor_identity :: proc(t: ^testing.T) {
    tab: Tab
    views: [3]^Instance_View
    for index in 0..<3 {
        views[index] = new(Instance_View)
        testing.expect(t, views[index] != nil)
        if views[index] == nil do return
        defer free(views[index])
    }
    tab.root = new_pane_leaf(0)
    testing.expect(t, tab.root != nil)
    if tab.root == nil do return
    defer destroy_pane_nodes(tab.root)
    tab.panes[0] = views[0]
    tab.pane_count = 1

    second, ok := split_pane_slot(&tab, 0, views[1], .Vertical)
    testing.expect(t, ok)
    third: int
    third, ok = split_pane_slot(&tab, second, views[2], .Vertical)
    testing.expect(t, ok)
    testing.expect_value(t, tab.pane_count, 3)

    removed: ^Instance_View
    removed, ok = remove_pane_slot(&tab, second)
    testing.expect(t, ok)
    testing.expect(t, removed == views[1])
    testing.expect_value(t, tab.pane_count, 2)
    testing.expect(t, pane_leaf_for_index(tab.root, 0) != nil)
    testing.expect(t, pane_leaf_for_index(tab.root, third) != nil)
    testing.expect(t, pane_leaf_for_index(tab.root, second) == nil)
    testing.expect_value(t, tab.active_pane, third)

    removed, ok = remove_pane_slot(&tab, third)
    testing.expect(t, ok)
    testing.expect(t, removed == views[2])
    testing.expect_value(t, tab.pane_count, 1)
    testing.expect(t, tab.root.kind == .Leaf)
    testing.expect_value(t, tab.root.pane_index, 0)
    testing.expect_value(t, tab.active_pane, 0)
}

@(test)
pane_tree_directional_focus_resize_zoom_and_swap_are_geometry_owned :: proc(t: ^testing.T) {
    tab: Tab
    views: [3]^Instance_View
    for index in 0..<3 {
        views[index] = new(Instance_View)
        testing.expect(t, views[index] != nil)
        if views[index] == nil do return
        defer free(views[index])
    }
    tab.root = new_pane_leaf(0)
    testing.expect(t, tab.root != nil)
    if tab.root == nil do return
    defer destroy_pane_nodes(tab.root)
    tab.panes[0] = views[0]
    tab.pane_count = 1
    second, ok := split_pane_slot(&tab, 0, views[1], .Vertical)
    testing.expect(t, ok)
    third: int
    third, ok = split_pane_slot(&tab, second, views[2], .Horizontal)
    testing.expect(t, ok)
    inset := SDL.FRect{0, 0, 1000, 600}

    testing.expect_value(t, tab.active_pane, third)
    testing.expect(t, focus_pane_direction(&tab, inset, .Up))
    testing.expect_value(t, tab.active_pane, second)
    testing.expect(t, focus_pane_direction(&tab, inset, .Left))
    testing.expect_value(t, tab.active_pane, 0)
    testing.expect(t, focus_pane_direction(&tab, inset, .Right))
    testing.expect_value(t, tab.active_pane, second)

    leaf := pane_leaf_for_index(tab.root, second)
    testing.expect(t, leaf != nil && leaf.parent != nil)
    if leaf != nil && leaf.parent != nil {
        old_ratio := leaf.parent.ratio
        testing.expect(t, resize_active_divider(&tab, .Down))
        testing.expect(t, leaf.parent.ratio > old_ratio)
    }

    active_before := tab.panes[tab.active_pane]
    testing.expect(t, swap_active_pane_direction(&tab, inset, .Left))
    testing.expect(t, tab.panes[tab.active_pane] == active_before)
    testing.expect_value(t, tab.active_pane, 0)

    testing.expect(t, toggle_pane_zoom(&tab))
    zoomed := pane_layout(&tab, inset)
    testing.expect_value(t, zoomed.entry_count, 1)
    testing.expect_value(t, zoomed.entries[0].pane_index, tab.active_pane)
    testing.expect(t, abs(zoomed.entries[0].rect.w - inset.w) < 0.01)
    testing.expect(t, toggle_pane_zoom(&tab))
    normal := pane_layout(&tab, inset)
    testing.expect_value(t, normal.entry_count, 3)
}

@(test)
pane_divider_pointer_ratio_is_orientation_aware_and_clamped :: proc(t: ^testing.T) {
    container := SDL.FRect{100, 50, 800, 600}
    testing.expect(t, abs(pane_divider_ratio_for_pointer(.Vertical, container, 500, 0) - f32(0.5025)) < 0.01)
    testing.expect_value(t, pane_divider_ratio_for_pointer(.Vertical, container, -1000, 0), f32(0.15))
    testing.expect_value(t, pane_divider_ratio_for_pointer(.Vertical, container, 5000, 0), f32(0.85))
    testing.expect(t, abs(pane_divider_ratio_for_pointer(.Horizontal, container, 0, 350) - f32(0.5033)) < 0.01)
    testing.expect_value(t, pane_divider_ratio_for_pointer(.Horizontal, container, 0, -1000), f32(0.15))
    testing.expect_value(t, pane_divider_ratio_for_pointer(.Horizontal, container, 0, 5000), f32(0.85))
}

@(test)
pane_directional_keyboard_capabilities_are_visible_unbound_mappings :: proc(t: ^testing.T) {
    focus, resize, swap := 0, 0, 0
    for definition in KEY_MAPPING_DEFINITIONS {
        #partial switch definition.target.kind {
        case .Pane_Focus: focus += 1
        case .Pane_Resize: resize += 1
        case .Pane_Swap: swap += 1
        case:
        }
        if definition.target.kind == .Pane_Focus || definition.target.kind == .Pane_Resize || definition.target.kind == .Pane_Swap {
            testing.expect_value(t, definition.default_shortcut, "")
        }
    }
    testing.expect_value(t, focus, 4)
    testing.expect_value(t, resize, 4)
    testing.expect_value(t, swap, 4)
}
