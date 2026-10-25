#!/usr/bin/env bash
set -euo pipefail

host=$(cd "$(dirname "$0")" && pwd)
mode=${1:-debug}
if [[ $# -gt 0 ]]; then shift; fi
case "$mode" in
  debug|profile|release) ;;
  *) echo 'usage: build-android.sh [debug|profile|release] [flutter flags...]' >&2; exit 64 ;;
esac

"$host/native/build-android.sh"
(cd "$host" && flutter pub get && flutter build apk "--$mode" --target-platform android-arm64 "$@")
apk="$host/build/app/outputs/flutter-apk/app-$mode.apk"
test -f "$apk"
unzip -Z1 "$apk" | grep -Fx 'lib/arm64-v8a/libhowl_sessions_native.so'
abis=$(unzip -Z1 "$apk" | sed -n 's#^lib/\([^/]*\)/.*#\1#p' | sort -u)
if [[ "$abis" != arm64-v8a ]]; then
  printf 'unexpected Android ABIs:\n%s\n' "$abis" >&2
  exit 1
fi
sha256sum "$apk"
echo "HOWL_SESSIONS_ANDROID_APP_OK apk=$apk"
