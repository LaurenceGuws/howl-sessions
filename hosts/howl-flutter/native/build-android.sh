#!/usr/bin/env bash
set -euo pipefail

host=$(cd "$(dirname "$0")/.." && pwd)
workspace=$(cd "$host/../.." && pwd)
ndk=${ANDROID_NDK_ROOT:-}
if [[ -z "$ndk" ]]; then
  echo 'ANDROID_NDK_ROOT must name the Android NDK used for this release' >&2
  exit 2
fi
toolchain="$ndk/toolchains/llvm/prebuilt/linux-x86_64"
if [[ ! -d "$toolchain/sysroot" ]]; then
  echo 'Android NDK Linux toolchain is missing' >&2
  exit 2
fi
if [[ "$(zig version)" != "$(cat "$workspace/.zigversion")" ]]; then
  echo 'Zig does not match the pinned Howl Sessions compiler' >&2
  exit 2
fi

work="$host/native/.work/android-arm64"
mkdir -p "$work"
sysroot="$toolchain/sysroot"
# Zig uses NDK libc headers and crt files for Android API 24, not host glibc.
printf 'include_dir=%s\nsys_include_dir=%s\ncrt_dir=%s\ncc_dir=%s\nmsvc_lib_dir=\nkernel32_lib_dir=\ndarwin_sdk_dir=\n' \
  "$sysroot/usr/include" \
  "$sysroot/usr/include/aarch64-linux-android" \
  "$sysroot/usr/lib/aarch64-linux-android/24" \
  "$sysroot/usr/lib/aarch64-linux-android/24" \
  >"$work/libc.txt"

(cd "$workspace/mods/server-client" && zig build install \
  -Dtarget=aarch64-linux-android.24 \
  -Doptimize=ReleaseFast \
  -Dshared-abi=true \
  --libc "$work/libc.txt" \
  -p "$work/install")

library="$work/install/lib/libhowl_server_client.so"
if [[ ! -f "$library" ]]; then
  echo "Server client shared ABI not produced: $library" >&2
  exit 1
fi
dest="$host/native/android/arm64-v8a"
mkdir -p "$dest"
install -m 0644 "$library" "$dest/libhowl_server_client.so"
"$toolchain/bin/llvm-readelf" -h "$dest/libhowl_server_client.so" | grep 'AArch64'
"$toolchain/bin/llvm-nm" -D --defined-only "$dest/libhowl_server_client.so" | grep ' hsc_control_tree$'
sha256sum "$dest/libhowl_server_client.so"
echo 'HOWL_SESSIONS_ANDROID_CLIENT_OK'
