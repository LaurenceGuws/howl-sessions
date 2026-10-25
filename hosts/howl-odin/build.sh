#!/usr/bin/env bash
set -euo pipefail

module_root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$module_root/../.." && pwd)
bridge_root="$module_root/native"
output_root="$module_root/zig-out/bin"
bridge_lib="$bridge_root/zig-out/lib/libhowl_odin_bridge.so"

install_atomically() {
  local source=$1
  local destination=$2
  local staged="${destination}.new.$$"
  cp "$source" "$staged"
  mv -f "$staged" "$destination"
}

expected_zig=$(cat "$repo_root/.zigversion")
actual_zig=$(zig version)
[[ $actual_zig == "$expected_zig" ]] || {
  printf 'howl-odin: Zig mismatch: expected %s, got %s\n' "$expected_zig" "$actual_zig" >&2
  exit 1
}

expected_odin=$(cat "$module_root/.odinversion")
actual_odin=$(odin version | awk '{print $3}')
[[ $actual_odin == "$expected_odin" ]] || {
  printf 'howl-odin: Odin mismatch: expected %s, got %s\n' "$expected_odin" "$actual_odin" >&2
  exit 1
}

(
  cd "$bridge_root"
  zig build test -Doptimize=ReleaseSafe
  zig build install -Doptimize=ReleaseSafe
)

mkdir -p "$output_root"
LD_LIBRARY_PATH="$bridge_root/zig-out/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  odin test "$module_root" \
  -collection:bridge="$bridge_root/zig-out/lib" \
  -collection:howl_core="$bridge_root/zig-out/bindings" \
  -define:ODIN_TEST_FANCY=false
odin check "$module_root" -collection:bridge="$bridge_root/zig-out/lib" -collection:howl_core="$bridge_root/zig-out/bindings"
# Keep debug symbols, assertions and bounds checks, but optimize the daily
# desktop instead of implicitly selecting -o:none through -debug.
# Keep the running desktop's executable inode intact while publishing a new build.
candidate="$output_root/.howl-odin.build.$$"
trap 'rm -f -- "$candidate"' EXIT
odin build "$module_root" \
  -collection:bridge="$bridge_root/zig-out/lib" \
  -collection:howl_core="$bridge_root/zig-out/bindings" \
  -out:"$candidate" \
  -debug -o:speed
install_atomically "$candidate" "$output_root/howl-odin"
install_atomically "$bridge_lib" "$output_root/libhowl_odin_bridge.so"
install_atomically "$module_root/packaging/howl-window-icon.bmp" "$output_root/howl-window-icon.bmp"

printf 'howl-odin: built %s\n' "$output_root/howl-odin"
