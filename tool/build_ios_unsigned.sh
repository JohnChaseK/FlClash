#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$task_root"
task_flutter="${FLUTTER_BIN:-flutter}"
"$task_flutter" pub get
"$task_root/tool/build_ios_core.sh"
"$task_flutter" build ios --release --no-codesign "$@"

task_app="$task_root/build/ios/iphoneos/Runner.app"
task_extension="$task_app/PlugIns/PacketTunnel.appex"
[[ -x "$task_app/Runner" && -x "$task_extension/PacketTunnel" ]] || {
  echo 'Runner.app or PacketTunnel.appex is missing; refusing to package an incomplete IPA.' >&2
  exit 1
}
task_stage="$(mktemp -d "$task_root/build/ios/unsigned.XXXXXX")"
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$task_stage"' EXIT
mkdir -p "$task_stage/Payload"
ditto "$task_app" "$task_stage/Payload/Runner.app"
mkdir -p "$task_root/build/ios/ipa"
ditto -c -k --keepParent "$task_stage/Payload" "$task_root/build/ios/ipa/FlClash-unsigned.ipa"
printf 'Unsigned IPA: %s\n' "$task_root/build/ios/ipa/FlClash-unsigned.ipa"
