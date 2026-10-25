package server_native

import vt_native "../../../../../howl/mods/howl-vt/bindings/odin"

// The transport owner adds authority; terminal fields remain VT-owned.
Request_Info :: struct {
    request: vt_native.Request_Info,
    authority_client_id: u64,
}
