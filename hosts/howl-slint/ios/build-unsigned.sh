#!/usr/bin/env bash
# Unsigned device package. Home's ios/Splice owns provisioning and installation.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$root/../.." && pwd)
[[ $(uname -s) == Darwin ]] || { echo 'iOS requires macOS/Xcode' >&2; exit 2; }
[[ $(zig version) == "$(cat "$repo/.zigversion")" ]]
: "${HOWL_IOS_OUTPUT:?Set HOWL_IOS_OUTPUT to a dedicated build-output directory}"
[[ "$HOWL_IOS_OUTPUT" = /* ]] || { echo 'HOWL_IOS_OUTPUT must be absolute' >&2; exit 2; }
export IPHONEOS_DEPLOYMENT_TARGET=16.6
export SDKROOT=$(xcrun --sdk iphoneos --show-sdk-path)
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOWL_IOS_OUTPUT/cargo}"
cd "$root"
cargo build --locked --release --target aarch64-apple-ios --bin howl-slint
app="$HOWL_IOS_OUTPUT/Payload/HowlSlint.app"
[[ ! -e "$app" ]] || { echo 'Refusing to reuse an existing application package' >&2; exit 2; }
mkdir -p "$app"
cp "$CARGO_TARGET_DIR/aarch64-apple-ios/release/howl-slint" "$app/howl-slint"
cp ios/Info.plist "$app/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${GITHUB_RUN_NUMBER:-1}" "$app/Info.plist"
plutil -lint "$app/Info.plist"
# Static native linkage: no Home paths or unsigned third-party dylibs may escape.
xcrun otool -L "$app/howl-slint"
xcrun otool -L "$app/howl-slint" | tail -n +2 | awk '{print $1}' | while read -r library; do
    case "$library" in /System/Library/*|/usr/lib/*) ;; *) echo "Unexpected dynamic dependency: $library" >&2; exit 1;; esac
done
xcrun lipo -verify_arch arm64 "$app/howl-slint"
cd "$HOWL_IOS_OUTPUT"
/usr/bin/ditto -c -k --keepParent Payload howl-slint.ipa
shasum -a 256 howl-slint.ipa > SHA256SUMS
printf 'Unsigned IPA: %s/howl-slint.ipa\n' "$HOWL_IOS_OUTPUT"
