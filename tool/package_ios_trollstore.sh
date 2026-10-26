#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_input="${1:-$task_root/build/ios/ipa/FlClash-unsigned.ipa}"
if [[ "$#" -gt 1 || ! -f "$task_input" ]]; then
  echo 'Usage: ./tool/package_ios_trollstore.sh [unsigned.ipa]' >&2
  echo 'Build the unsigned IPA with ./tool/build_ios_unsigned.sh first.' >&2
  exit 1
fi
mkdir -p "$task_root/build/ios/ipa"
task_output="$task_root/build/ios/ipa/FlClash-TrollStore.ipa"
if [[ "$task_input" -ef "$task_output" ]]; then
  echo 'Input IPA must differ from the TrollStore output path.' >&2
  exit 1
fi
task_stage="$(mktemp -d "$task_root/build/ios/trollstore.XXXXXX")"
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$task_stage"' EXIT
ditto -x -k --norsrc --noextattr --noqtn "$task_input" "$task_stage"
task_app="$task_stage/Payload/Runner.app"
task_extension="$task_app/PlugIns/PacketTunnel.appex"

python3 - "$task_root" "$task_stage" <<'PY'
from pathlib import Path
import plistlib
import sys

root, stage = map(Path, sys.argv[1:])
for metadata in (stage / 'Payload').rglob('._*'):
    if metadata.is_file():
        metadata.unlink()
bundles = [
    (stage / 'Payload/Runner.app', root / 'ios/Runner/Runner.entitlements', 'runner'),
    (stage / 'Payload/Runner.app/PlugIns/PacketTunnel.appex',
     root / 'ios/PacketTunnel/PacketTunnel.entitlements', 'tunnel'),
]
infos = [plistlib.loads((bundle / 'Info.plist').read_bytes()) for bundle, _, _ in bundles]
app_id = infos[0]['CFBundleIdentifier']
app_group = infos[0]['FlClashAppGroup']
if infos[1]['CFBundleIdentifier'] != app_id + '.PacketTunnel':
    raise SystemExit('PacketTunnel bundle ID does not match Runner.')
if not app_group.startswith('group.') or '$' in app_group:
    raise SystemExit('Runner has an invalid or unexpanded App Group.')
if infos[1]['FlClashAppGroup'] != app_group:
    raise SystemExit('Runner and PacketTunnel must use the same App Group.')

for (bundle, source, name), info in zip(bundles, infos):
    if not (bundle / info['CFBundleExecutable']).is_file():
        raise SystemExit(f'Missing executable in {bundle.name}.')
    entitlements = plistlib.loads(source.read_bytes())
    entitlements['com.apple.security.application-groups'] = [app_group]
    if 'packet-tunnel-provider' not in entitlements.get(
        'com.apple.developer.networking.networkextension', []
    ):
        raise SystemExit(f'Missing packet tunnel capability in {source.name}.')
    entitlements['application-identifier'] = 'TROLLTROLL.' + info['CFBundleIdentifier']
    entitlements['com.apple.developer.team-identifier'] = 'TROLLTROLL'
    (stage / f'{name}-entitlements.plist').write_bytes(plistlib.dumps(entitlements))
    print(f'{name}: {info["CFBundleIdentifier"]}, App Group: {app_group}')
PY

while IFS= read -r -d '' task_library; do
  codesign --force --sign - --timestamp=none "$task_library"
done < <(find "$task_app" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0)
codesign --force --sign - --timestamp=none --generate-entitlement-der \
  --entitlements "$task_stage/tunnel-entitlements.plist" "$task_extension"
codesign --force --sign - --timestamp=none --generate-entitlement-der \
  --entitlements "$task_stage/runner-entitlements.plist" "$task_app"
codesign --verify --deep --strict --verbose=2 "$task_app"

python3 - "$task_stage" <<'PY'
from pathlib import Path
import plistlib
import subprocess
import sys

stage = Path(sys.argv[1])
for relative, name in [
    ('Payload/Runner.app', 'runner'),
    ('Payload/Runner.app/PlugIns/PacketTunnel.appex', 'tunnel'),
]:
    result = subprocess.run(
        ['codesign', '--display', '--entitlements', '-', '--xml', str(stage / relative)],
        check=True, capture_output=True,
    )
    actual = plistlib.loads(result.stdout)
    expected = plistlib.loads((stage / f'{name}-entitlements.plist').read_bytes())
    if actual != expected:
        raise SystemExit(f'Embedded entitlements do not match for {name}.')
    print(f'Verified embedded entitlements: {name}')
PY

ditto -c -k --norsrc --noextattr --noqtn --keepParent \
  "$task_stage/Payload" "$task_stage/FlClash-TrollStore.ipa"
mv "$task_stage/FlClash-TrollStore.ipa" "$task_output"
printf 'TrollStore IPA: %s\n' "$task_output"
shasum -a 256 "$task_output"
