package main

import "core:testing"
import instance_native "howl_core:instance"
import render_native "howl_core:render"

@(test)
native_frame_owner_layouts :: proc(t: ^testing.T) {
    testing.expect(t, size_of(instance_native.Frame_Info) == 88)
    testing.expect(t, offset_of(instance_native.Frame_Info, command_count) == 40)
    testing.expect(t, offset_of(instance_native.Frame_Info, surface_width) == 72)
    testing.expect(t, size_of(render_native.Resource_Info) == 40)
    testing.expect(t, size_of(render_native.Command_Info) == 64)
    testing.expect(t, offset_of(render_native.Command_Info, tag) == 56)
}
