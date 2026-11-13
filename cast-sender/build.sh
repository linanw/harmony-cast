#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" == Darwin ]]; then
  deveco_default=/Applications/DevEco-Studio.app/Contents
else
  deveco_default=/opt/devecostudio
fi
export DEVECO_HOME="${DEVECO_HOME:-$deveco_default}"
export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$DEVECO_HOME/sdk}"
export JAVA_HOME="${JAVA_HOME:-$DEVECO_HOME/jbr}"
export PATH="$DEVECO_HOME/tools/node/bin:$DEVECO_HOME/tools/ohpm/bin:$JAVA_HOME/bin:$PATH"
mode="${1:-}"
if [[ "$mode" != "" && "$mode" != --signed && "$mode" != --install ]]; then
  echo 'Usage: ./build.sh [--signed|--install]' >&2; exit 2
fi
if [[ -n "$mode" ]]; then
  profile="${HARMONY_CAST_SIGNING_PROFILE:-$HOME/.ohos/config/cast-sender-build-profile.json5}"
  [[ -r "$profile" ]] || { echo '请先在 DevEco Studio 的 Signing Configs 中配置此应用签名。' >&2; exit 1; }
  backup=$(mktemp)
  cp -p build-profile.json5 "$backup"
  trap 'mv "$backup" build-profile.json5' EXIT
  install -m 600 "$profile" build-profile.json5
fi
ohpm install
"$DEVECO_HOME/tools/hvigor/bin/hvigorw" assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
if [[ "$mode" == --install ]]; then
  result=$("$DEVECO_SDK_HOME/default/openharmony/toolchains/hdc" install -r entry/build/default/outputs/default/entry-default-signed.hap)
  printf '%s\n' "$result"
  [[ "$result" == *'install bundle successfully'* ]] || exit 1
fi
