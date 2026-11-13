#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# Build outside cloud-synced Documents, whose Finder metadata can invalidate a
# bundle's resource seal between xattr and codesign.
build_root=$(mktemp -d "${TMPDIR:-/tmp/}harmony-cast-build.XXXXXX")
app="$build_root/Harmony Cast.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 \
  Sources/*.swift -o "$app/Contents/MacOS/HarmonyCast" \
  -framework AppKit -framework AVFoundation -framework Network -framework VideoToolbox
cp Info.plist "$app/Contents/Info.plist"
iconutil -c icns Resources/HarmonyCast.iconset -o "$app/Contents/Resources/HarmonyCast.icns"
xattr -cr "$app"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
mkdir -p dist
ditto -c -k --norsrc --noextattr --keepParent "$app" "$PWD/dist/Harmony-Cast-macOS-arm64.zip"
printf '%s\n' "$app"
