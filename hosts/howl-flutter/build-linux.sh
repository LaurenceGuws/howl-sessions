#!/usr/bin/env bash
set -euo pipefail

host=$(cd "$(dirname "$0")" && pwd)
workspace=$(cd "$host/../.." && pwd)
mode=${1:-debug}
if [[ $# -gt 0 ]]; then shift; fi
case "$mode" in
  debug) optimize=Debug ;;
  profile|release) optimize=ReleaseFast ;;
  *) echo 'usage: build-linux.sh [debug|profile|release] [flutter flags...]' >&2; exit 64 ;;
esac
if [[ "$(zig version)" != "$(cat "$workspace/.zigversion")" ]]; then
  echo 'Zig does not match the pinned Howl Sessions compiler' >&2
  exit 2
fi
command -v ninja >/dev/null || {
  echo 'Ninja is required; put the installed Ninja directory on PATH' >&2
  exit 2
}
work="$host/native/.work/linux"
(cd "$workspace/mods/server-client-render" && zig build install \
  -Doptimize="$optimize" -p "$work/install")
(cd "$host" && flutter pub get && flutter build linux "--$mode" "$@")
case "$(uname -m)" in
  x86_64) arch=x64 ;;
  aarch64) arch=arm64 ;;
  *) echo 'Unsupported Linux host architecture' >&2; exit 2 ;;
esac
bundle="$host/build/linux/$arch/$mode/bundle"
install -m 0644 "$work/install/lib/libhowl_sessions_native.so" "$bundle/lib/"
nm -D --defined-only "$bundle/lib/libhowl_sessions_native.so" | grep ' hsc_control_status$' >/dev/null
nm -D --defined-only "$bundle/lib/libhowl_sessions_native.so" | grep ' hsr_capture$' >/dev/null
sha256sum "$bundle/howl_sessions" "$bundle/lib/libhowl_sessions_native.so"
echo "HOWL_SESSIONS_LINUX_APP_OK bundle=$bundle"
