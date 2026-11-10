#!/usr/bin/env bash
set -euo pipefail

module_root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
app_id=io.github.laurenceguws.howl
prefix="$HOME/.local"
data_home="${XDG_DATA_HOME:-$prefix/share}"
bundle_dir="$prefix/libexec/howl-odin"
bin_dir="$prefix/bin"
applications_dir="$data_home/applications"
icons_dir="$data_home/icons/hicolor/512x512/apps"
manifest="$bundle_dir/install-manifest.sha256"

usage() {
  cat <<'USAGE'
usage: ./install.sh --check | --promote | --uninstall

  --check      build and validate the candidate; verify owned-path safety
  --promote    atomically replace the user-local Howl Odin installation
  --uninstall  remove only an intact installation recorded by its manifest
USAGE
}

case ${1:-} in
  --check|--promote|--uninstall) mode=$1 ;;
  *) usage >&2; exit 2 ;;
esac
[[ $# -eq 1 ]] || { usage >&2; exit 2; }

bundle_files=(
  "$bundle_dir/howl-odin"
  "$bundle_dir/libhowl_odin_bridge.so"
  "$bundle_dir/howl-window-icon.bmp"
  "$bin_dir/howl-odin"
  "$applications_dir/$app_id.desktop"
  "$icons_dir/$app_id.png"
)
relative_files=(
  "libexec/howl-odin/howl-odin"
  "libexec/howl-odin/libhowl_odin_bridge.so"
  "libexec/howl-odin/howl-window-icon.bmp"
  "bin/howl-odin"
  "xdg-data/applications/$app_id.desktop"
  "xdg-data/icons/hicolor/512x512/apps/$app_id.png"
)

installed_path_for_manifest_key() {
  local rel=$1
  case $rel in
    bin/*|libexec/*) printf '%s/%s\n' "$prefix" "$rel" ;;
    xdg-data/*) printf '%s/%s\n' "$data_home" "${rel#xdg-data/}" ;;
    *) return 1 ;;
  esac
}

manifest_owns() {
  local rel=$1
  awk -v wanted="$rel" '$2 == wanted { found=1; exit } END { exit !found }' "$manifest"
}

verify_installed_manifest() {
  [[ -f $manifest ]] || return 1
  local expected rel path actual entries=0
  while read -r expected rel extra; do
    [[ -n ${expected:-} && -n ${rel:-} && -z ${extra:-} ]] || {
      printf 'howl-odin install: malformed manifest entry\n' >&2
      return 1
    }
    path=$(installed_path_for_manifest_key "$rel") || {
      printf 'howl-odin install: unsafe manifest path: %s\n' "$rel" >&2
      return 1
    }
    [[ -f $path ]] || {
      printf 'howl-odin install: managed file missing: %s\n' "$path" >&2
      return 1
    }
    actual=$(sha256sum "$path" | awk '{print $1}')
    [[ $actual == "$expected" ]] || {
      printf 'howl-odin install: managed file changed: %s\n' "$path" >&2
      return 1
    }
    entries=$((entries + 1))
  done < "$manifest"
  (( entries > 0 )) || {
    printf 'howl-odin install: empty manifest\n' >&2
    return 1
  }
}

check_destination_safety() {
  if [[ -e $manifest ]]; then
    verify_installed_manifest || {
      printf 'howl-odin install: refusing to overwrite a modified/incomplete installation\n' >&2
      exit 1
    }
    local index path rel
    for index in "${!bundle_files[@]}"; do
      path=${bundle_files[$index]}
      rel=${relative_files[$index]}
      if [[ -e $path || -L $path ]] && ! manifest_owns "$rel"; then
        printf 'howl-odin install: refusing unrelated existing path: %s\n' "$path" >&2
        exit 1
      fi
    done
    return
  fi
  local path
  for path in "${bundle_files[@]}"; do
    [[ ! -e $path && ! -L $path ]] || {
      printf 'howl-odin install: refusing unrelated existing path: %s\n' "$path" >&2
      exit 1
    }
  done
}

atomic_install() {
  local source=$1 destination=$2 mode_bits=$3
  local staged="${destination}.new.$$"
  install -m "$mode_bits" "$source" "$staged"
  mv -f "$staged" "$destination"
}

if [[ $mode == --uninstall ]]; then
  verify_installed_manifest || {
    printf 'howl-odin install: refusing uninstall because the recorded installation is missing or changed\n' >&2
    exit 1
  }
  while read -r _hash rel _extra; do
    path=$(installed_path_for_manifest_key "$rel") || exit 1
    rm -- "$path"
  done < "$manifest"
  rm -- "$manifest"
  rmdir --ignore-fail-on-non-empty "$bundle_dir" "$icons_dir" "$applications_dir" "$bin_dir" 2>/dev/null || true
  command -v update-desktop-database >/dev/null && update-desktop-database "$applications_dir" >/dev/null 2>&1 || true
  printf 'howl-odin install: uninstalled intact user-local installation\n'
  exit 0
fi

"$module_root/build.sh"
output_root="$module_root/zig-out/bin"
desktop_source="$module_root/packaging/$app_id.desktop"
icon_source="$module_root/packaging/$app_id.png"
launcher_source="$module_root/packaging/howl-odin-launcher"

for candidate in \
  "$output_root/howl-odin" \
  "$output_root/libhowl_odin_bridge.so" \
  "$output_root/howl-window-icon.bmp" \
  "$desktop_source" \
  "$icon_source" \
  "$launcher_source"; do
  [[ -s $candidate ]] || { printf 'howl-odin install: missing candidate: %s\n' "$candidate" >&2; exit 1; }
done
[[ -x $output_root/howl-odin && -x $launcher_source ]] || {
  printf 'howl-odin install: executable candidate missing execute permission\n' >&2
  exit 1
}
desktop-file-validate "$desktop_source"
readelf -d "$output_root/howl-odin" | grep -Fq 'Library runpath: [$ORIGIN]' || {
  printf 'howl-odin install: executable must retain RUNPATH=$ORIGIN\n' >&2
  exit 1
}
if ldd "$output_root/howl-odin" | grep -Fq 'not found'; then
  printf 'howl-odin install: candidate has unresolved shared libraries\n' >&2
  exit 1
fi
check_destination_safety

if [[ $mode == --check ]]; then
  printf 'howl-odin install: candidate and owned paths are safe\n'
  exit 0
fi

mkdir -p "$bundle_dir" "$bin_dir" "$applications_dir" "$icons_dir"
atomic_install "$output_root/howl-odin" "$bundle_dir/howl-odin" 0755
atomic_install "$output_root/libhowl_odin_bridge.so" "$bundle_dir/libhowl_odin_bridge.so" 0755
atomic_install "$output_root/howl-window-icon.bmp" "$bundle_dir/howl-window-icon.bmp" 0644
atomic_install "$launcher_source" "$bin_dir/howl-odin" 0755
atomic_install "$desktop_source" "$applications_dir/$app_id.desktop" 0644
atomic_install "$icon_source" "$icons_dir/$app_id.png" 0644

manifest_staged="${manifest}.new.$$"
: > "$manifest_staged"
for index in "${!bundle_files[@]}"; do
  printf '%s  %s\n' \
    "$(sha256sum "${bundle_files[$index]}" | awk '{print $1}')" \
    "${relative_files[$index]}" >> "$manifest_staged"
done
chmod 0644 "$manifest_staged"
mv -f "$manifest_staged" "$manifest"
command -v update-desktop-database >/dev/null && update-desktop-database "$applications_dir" >/dev/null 2>&1 || true
printf 'howl-odin install: promoted %s\n' "$bundle_dir"
