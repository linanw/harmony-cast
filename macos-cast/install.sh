#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
[[ -f 'dist/Harmony-Cast-macOS-arm64.zip' ]] || ./build.sh
destination="$HOME/Applications/Harmony Cast.app"
mkdir -p "$HOME/Applications"
stage=$(mktemp -d "$HOME/Applications/.harmony-cast-install.XXXXXX")
cleanup() {
  if [[ ! -e "$destination" && -d "$stage/previous.app" ]]; then
    mv "$stage/previous.app" "$destination"
  fi
  rm -rf -- "$stage"
}
trap cleanup EXIT
ditto -x -k --norsrc --noextattr 'dist/Harmony-Cast-macOS-arm64.zip' "$stage"
app="$stage/Harmony Cast.app"
xattr -cr "$app"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
# Replace the bundle without rewriting an executable that may be running.
[[ ! -e "$destination" ]] || mv "$destination" "$stage/previous.app"
mv "$app" "$destination"
if [[ "${1:-}" != --no-open ]]; then open "$destination"; fi
