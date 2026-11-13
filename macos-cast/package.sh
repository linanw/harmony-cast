#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
python="${DMG_PYTHON:-python3}"
"$python" -c 'import dmgbuild' 2>/dev/null || {
  echo 'DMG 打包需要 dmgbuild：在 Python 虚拟环境安装 packaging/requirements.txt，再设置 DMG_PYTHON。' >&2
  exit 1
}
app=$(./build.sh)
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
package_root=$(mktemp -d "${TMPDIR:-/tmp/}harmony-cast-dmg.XXXXXX")
tiffutil -cathidpicheck packaging/background.png packaging/background@2x.png -out "$package_root/background.tiff"
output="$PWD/dist/Harmony-Cast-$version-macOS-arm64.dmg"
"$python" -m dmgbuild -s packaging/dmg-settings.py -D app="$app" \
  -D background="$package_root/background.tiff" '鸿蒙投屏' "$output"
hdiutil verify "$output"
(cd dist && shasum -a 256 "Harmony-Cast-$version-macOS-arm64.dmg" Harmony-Cast-macOS-arm64.zip > SHA256SUMS)
printf '%s\n' "$output"
