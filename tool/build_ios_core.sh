#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_output="$task_root/ios/Frameworks/FlClashCore.xcframework"
task_cache="$task_root/build/ios/core"
task_targets="${IOS_CORE_TARGETS:-ios}"
if [[ "${PLATFORM_NAME:-}" == "iphonesimulator" ]]; then
  task_targets="ios,iossimulator"
fi
mkdir -p "$task_cache/bin" "$(dirname "$task_output")"
command -v go >/dev/null || { echo 'Go 1.27 or newer is required to build the iOS Core.' >&2; exit 1; }

task_fingerprint="$(python3 - "$task_root" "$task_targets" "$(go version)" <<'PY'
import hashlib
from pathlib import Path
import sys
root = Path(sys.argv[1])
digest = hashlib.sha256((' '.join(sys.argv[2:])).encode())
paths = list((root / 'core').rglob('*.go'))
paths += [root / name for name in [
    'core/go.mod', 'core/go.sum', 'core/Clash.Meta/component/ca/ca-certificates.crt',
    'build_config.yaml', 'tool/build_ios_core.sh',
]]
for path in sorted(paths):
    digest.update(str(path.relative_to(root)).encode())
    digest.update(path.read_bytes())
print(digest.hexdigest())
PY
)"
if [[ -d "$task_output" && -f "$task_cache/fingerprint" ]] &&
   [[ "$(cat "$task_cache/fingerprint")" == "$task_fingerprint" ]]; then
  exit 0
fi

cd "$task_root/core"
go build -o "$task_cache/bin/" golang.org/x/mobile/cmd/gomobile golang.org/x/mobile/cmd/gobind
export PATH="$task_cache/bin:$PATH"
task_tags="$(sed -n 's/^tags: *//p' "$task_root/build_config.yaml")"
task_version="$(sed -n 's/^core_version: *//p' "$task_root/build_config.yaml")"
task_godebug="$(go list -f '{{.DefaultGODEBUG}}' ./cmd/core)"
gomobile bind -target="$task_targets" -iosversion=15.0 \
  -tags="${task_tags},with_low_memory,no_zerotier,no_easytier,no_tailscale" \
  -ldflags="-s -w -X=github.com/metacubex/mihomo/constant.Version=${task_version} -X=runtime.godebugDefault=${task_godebug}" \
  -o "$task_output" ./apple
printf '%s\n' "$task_fingerprint" > "$task_cache/fingerprint"
