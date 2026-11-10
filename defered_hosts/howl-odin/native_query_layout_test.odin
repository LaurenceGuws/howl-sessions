package main

import "core:testing"
import vt_native "howl_core:vt"

@(test)
native_query_layout :: proc(t: ^testing.T) {
    testing.expect(t, size_of(vt_native.Search_Match_Info) == 32)
    testing.expect(t, offset_of(vt_native.Search_Match_Info, scanned_snapshots) == 24)
    testing.expect(t, size_of(vt_native.Selection_Range_Info) == 20)
    testing.expect(t, offset_of(vt_native.Selection_Range_Info, _reserved) == 16)
    testing.expect(t, size_of(vt_native.Interaction_State_Info) == 16)
    testing.expect(t, offset_of(vt_native.Interaction_State_Info, mouse_tracking) == 12)
    testing.expect(t, size_of(vt_native.Row_Shape) == 4)
}

@(test)
native_request_layout :: proc(t: ^testing.T) {
    testing.expect(t, size_of(vt_native.Request_Info) == 56)
    testing.expect(t, offset_of(vt_native.Request_Info, data) == 24)
    testing.expect(t, size_of(vt_native.Request_Data) == 32)
    testing.expect(t, offset_of(vt_native.Request_Info, payload_len) == 16)
    testing.expect(t, offset_of(vt_native.Request_Info, kind) == 20)
    testing.expect(t, offset_of(vt_native.Request_Clipboard, selection_len) == 4)
    testing.expect(t, offset_of(vt_native.Request_Drag, kind) == 12)
    testing.expect(t, offset_of(vt_native.Request_Drag, has_client_id) == 16)
    testing.expect(t, size_of(vt_native.Request_Container) == 28)
    testing.expect(t, size_of(vt_native.Request_Pointer) == 16)
}

@(test)
native_request_policy_keeps_pointer_reply_and_container_truth :: proc(t: ^testing.T) {
    info := vt_native.Request_Info{kind = u8(vt_native.Request_Kind.Pointer_Shape)}
    info.data.pointer_shape.query_requested = 1
    testing.expect(t, request_action_for(info) == .Reply_Pointer_Default)
    info = vt_native.Request_Info{kind = u8(vt_native.Request_Kind.Container), reply_required = 1}
    info.data.container.operation = u8(vt_native.Container_Operation.Report_Screen_Cells)
    testing.expect(t, request_action_for(info) == .Reply_Container_Screen)
    info.data.container.operation = u8(vt_native.Container_Operation.Report_Position)
    testing.expect(t, request_action_for(info) == .Reply_Container_Decline)
    info = vt_native.Request_Info{kind = u8(vt_native.Request_Kind.Notification)}
    info.data.notification.kind = u8(vt_native.Notification_Kind.Steal_Focus)
    testing.expect(t, request_action_for(info) == .Attention)
}
