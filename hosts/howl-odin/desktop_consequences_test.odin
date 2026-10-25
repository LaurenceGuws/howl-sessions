package main

import "core:testing"
import vt_native "../../../howl/mods/howl-vt/bindings/odin"
import server_native "../../mods/server-client/bindings/odin"

@(test)
desktop_request_layout_matches_owner :: proc(t: ^testing.T) {
    testing.expect(t, size_of(server_native.Request_Info) == 64)
    testing.expect(t, offset_of(server_native.Request_Info, authority_client_id) == 56)
    testing.expect_value(t, size_of(Consequence_Info), int(consequence_info_size()))
}

@(test)
desktop_request_policy_flashes_only_bell_and_attention_families :: proc(t: ^testing.T) {
    bell := vt_native.Request_Info{kind = u8(vt_native.Request_Kind.Bell)}
    testing.expect(t, request_action_for(bell) == .Attention)
    message := vt_native.Request_Info{kind = u8(vt_native.Request_Kind.Notification)}
    message.data.notification.kind = u8(vt_native.Notification_Kind.Message)
    testing.expect(t, request_action_for(message) == .Consume)
    message.data.notification.kind = u8(vt_native.Notification_Kind.Steal_Focus)
    testing.expect(t, request_action_for(message) == .Attention)
    message.data.notification.kind = u8(vt_native.Notification_Kind.Request_Attention)
    testing.expect(t, request_action_for(message) == .Attention)
}

@(test)
desktop_request_policy_replies_to_canonical_queries :: proc(t: ^testing.T) {
    clipboard := vt_native.Request_Info{kind = u8(vt_native.Request_Kind.Clipboard), reply_required = 1}
    testing.expect(t, request_action_for(clipboard) == .Reply_Clipboard_Empty)
    pointer := vt_native.Request_Info{kind = u8(vt_native.Request_Kind.Pointer_Shape)}
    pointer.data.pointer_shape.query_requested = 1
    testing.expect(t, request_action_for(pointer) == .Reply_Pointer_Default)
    color := vt_native.Request_Info{kind = u8(vt_native.Request_Kind.Color_Preference), reply_required = 1}
    testing.expect(t, request_action_for(color) == .Reply_Color_Dark)
    container := vt_native.Request_Info{kind = u8(vt_native.Request_Kind.Container), reply_required = 1}
    container.data.container.operation = u8(vt_native.Container_Operation.Report_Screen_Cells)
    testing.expect(t, request_action_for(container) == .Reply_Container_Screen)
    container.data.container.operation = u8(vt_native.Container_Operation.Report_Position)
    testing.expect(t, request_action_for(container) == .Reply_Container_Decline)
}
