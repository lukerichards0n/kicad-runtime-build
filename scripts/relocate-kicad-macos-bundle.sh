#!/usr/bin/env bash
# Makes a built KiCad.app independent of Homebrew.
#
# KiCad's install step copies the libraries it links into the bundle and points
# every reference at the copy. It does not do that for the Python framework,
# which Homebrew builds with an absolute install name, nor for the libraries
# Python's own extension modules load. Left alone, the bundle only starts on a
# Mac that has the same Homebrew packages as the machine that built it.
#
# This rewrites those references to @rpath (every KiCad executable already
# searches Contents/Frameworks), copies in any library still loaded from
# outside the bundle, signs what it changed, and fails if a reference to
# anything but the bundle or the system remains. --check only does the last.
set -euo pipefail

usage() { echo "Usage: $0 [--check] path/to/KiCad.app" >&2; }
check_only=0; app=""
while (($#)); do
  case "$1" in
    --check) check_only=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
    *) app="$1"; shift ;;
  esac
done
[[ -d "$app/Contents/Frameworks" ]] || { echo "Not a KiCad.app bundle: ${app:-?}" >&2; usage; exit 2; }
frameworks="$app/Contents/Frameworks"
inside='^(@rpath|@executable_path|@loader_path|/usr/lib|/System)/'

python_version="$(ls "$frameworks/Python.framework/Versions" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+$' | head -n 1 || true)"
python_library="Python.framework/Versions/$python_version/Python"

# Lists are kept in files and read on their own descriptors: the bash that
# ships with macOS (3.2) leaks one for every <(...) used inside a loop.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
: > "$work/changed"

# Every Mach-O file in the bundle, one per line.
list_binaries() {
  find "$app/Contents" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' -o -name '*.kiface' \) |
    while IFS= read -r file; do
      case "$(file -b "$file")" in Mach-O*) printf '%s\n' "$file" ;; esac
    done
}

# The name a library gives itself, when that is a path outside the bundle.
outside_id() { otool -D "$1" | sed -n 2p | grep -E -v "$inside" || true; }

# The libraries a file loads from outside the bundle and the system.
outside_references() {
  local id
  id="$(otool -D "$1" | sed -n 2p)"
  otool -L "$1" | awk 'NR > 1 { print $1 }' | grep -E -v "$inside" | grep -F -x -v -- "$id" | sort -u || true
}

# install_name_tool, without its note that the signature is now stale: every
# changed file is signed again below.
rewrite() { install_name_tool "$@" 2>&1 | { grep -v 'will invalidate the code signature' || true; } >&2; }

relocate() {
  local changed=1 pass=0 file reference name
  while ((changed)); do
    changed=0
    pass=$((pass + 1))
    ((pass <= 8)) || { echo "Library references still change after 8 passes." >&2; exit 1; }
    list_binaries > "$work/binaries"
    while IFS= read -r file <&3; do
      if [[ -n "$(outside_id "$file")" ]]; then
        if [[ "$file" == "$frameworks/$python_library" ]]; then
          rewrite -id "@rpath/$python_library" "$file"
        else
          rewrite -id "@rpath/$(basename "$file")" "$file"
        fi
        printf '%s\n' "$file" >> "$work/changed"
        changed=1
      fi
      outside_references "$file" > "$work/references"
      while IFS= read -r reference <&4; do
        [[ -n "$reference" ]] || continue
        if [[ -n "$python_version" && "$reference" == */"$python_library" ]]; then
          rewrite -change "$reference" "@rpath/$python_library" "$file"
        else
          name="$(basename "$reference")"
          if [[ ! -e "$frameworks/$name" ]]; then
            [[ -f "$reference" ]] || { echo "$file loads $reference, which is not in the bundle or on this machine." >&2; exit 1; }
            cp -L "$reference" "$frameworks/$name"
            chmod u+w "$frameworks/$name"
            echo "Bundled $reference"
          fi
          rewrite -change "$reference" "@rpath/$name" "$file"
        fi
        printf '%s\n' "$file" >> "$work/changed"
        changed=1
      done 4< "$work/references"
    done 3< "$work/binaries"
  done
}

# Python's own launchers sit deeper than KiCad's executables; give them the
# way back to Contents/Frameworks so a bundled interpreter starts on its own.
add_search_path() {
  [[ -f "$1" ]] || return 0
  if ! otool -l "$1" | grep -A2 LC_RPATH | grep -q "path $2 "; then
    rewrite -add_rpath "$2" "$1"
    printf '%s\n' "$1" >> "$work/changed"
  fi
}

verify() {
  local file reference bad=0
  list_binaries > "$work/binaries"
  while IFS= read -r file <&3; do
    outside_references "$file" > "$work/references"
    while IFS= read -r reference <&4; do
      [[ -n "$reference" ]] || continue
      echo "$file loads $reference from outside the bundle." >&2
      bad=1
    done 4< "$work/references"
  done 3< "$work/binaries"
  return "$bad"
}

if ((!check_only)); then
  relocate
  if [[ -n "$python_version" ]]; then
    python_root="$frameworks/Python.framework/Versions/$python_version"
    add_search_path "$python_root/bin/python$python_version" "@executable_path/../../../.."
    add_search_path "$python_root/Resources/Python.app/Contents/MacOS/Python" "@executable_path/../../../../../../.."
  fi
  sort -u "$work/changed" > "$work/sign"
  while IFS= read -r file <&3; do
    codesign --force --sign - "$file" 2>&1 | { grep -v 'replacing existing signature' || true; } >&2
  done 3< "$work/sign"
  echo "Relocated $(wc -l < "$work/sign" | tr -d ' ') files in $app"
fi
verify || { echo "The bundle is not self-contained." >&2; exit 1; }
echo "Every library $app loads is inside the bundle or part of macOS."
