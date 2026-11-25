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
task_identity="${FLCLASH_SIGN_IDENTITY:-512CB2B4DEB1A6D3365E9329EDC13F2B4DA253A7}"
task_stage="$(mktemp -d "$task_root/build/ios/trollstore.XXXXXX")"
trap 'python3 -c "import shutil, sys; shutil.rmtree(sys.argv[1])" "$task_stage"' EXIT
ditto -x -k --norsrc --noextattr --noqtn "$task_input" "$task_stage"
task_app="$task_stage/Payload/Runner.app"
task_extension="$task_app/PlugIns/PacketTunnel.appex"

FLCLASH_SIGN_IDENTITY="$task_identity" python3 - "$task_root" "$task_stage" <<'PY'
from datetime import datetime, timezone
from pathlib import Path
import os
import plistlib
import re
import shutil
import subprocess
import sys

root, stage = map(Path, sys.argv[1:])
identity = os.environ['FLCLASH_SIGN_IDENTITY']
team_override = os.environ.get('FLCLASH_TEAM_ID', '').strip()
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

def certificate_pem(signing_identity):
    if re.fullmatch(r'[0-9A-Fa-f]{40}', signing_identity):
        wanted = signing_identity.upper().encode()
        dump = subprocess.check_output(['security', 'find-certificate', '-a', '-p', '-Z'])
        for chunk in dump.split(b'SHA-1 hash: ')[1:]:
            sha, _, rest = chunk.partition(b'\n')
            if sha.strip().upper() != wanted:
                continue
            start = rest.find(b'-----BEGIN CERTIFICATE-----')
            end = rest.find(b'-----END CERTIFICATE-----')
            if start < 0 or end < 0:
                break
            return rest[start:end + len(b'-----END CERTIFICATE-----')] + b'\n'
        raise SystemExit(f'No signing certificate matches {signing_identity}.')
    pem = subprocess.check_output(['security', 'find-certificate', '-c', signing_identity, '-p'])
    certs = re.findall(
        b'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', pem, re.S,
    )
    if len(certs) != 1:
        raise SystemExit(
            f'{signing_identity} matches {len(certs)} certificates; '
            'set FLCLASH_SIGN_IDENTITY to one SHA-1.',
        )
    return certs[0] + b'\n'

def subject_ou(pem):
    result = subprocess.run(
        ['openssl', 'x509', '-noout', '-subject', '-nameopt', 'RFC2253'],
        input=pem, capture_output=True, check=True,
    )
    subject = result.stdout.decode().strip().removeprefix('subject=').strip()
    parts = []
    current = []
    escaped = False
    for char in subject:
        if escaped:
            current.append(char)
            escaped = False
        elif char == '\\':
            escaped = True
        elif char == ',':
            parts.append(''.join(current).strip())
            current = []
        else:
            current.append(char)
    if current:
        parts.append(''.join(current).strip())
    values = [part.split('=', 1)[1] for part in parts if part.startswith('OU=')]
    if len(values) != 1 or not re.fullmatch(r'[A-Z0-9]{10}', values[0]):
        raise SystemExit(f'Could not read a team identifier from the signing certificate ({subject}).')
    return values[0]

if team_override:
    if not re.fullmatch(r'[A-Z0-9]{10}', team_override):
        raise SystemExit('FLCLASH_TEAM_ID must be a 10-character team identifier.')
    team = team_override
elif identity == '-':
    team = 'TROLLTROLL'
else:
    team = subject_ou(certificate_pem(identity))

def decode_profile(path):
    data = subprocess.check_output(
        ['security', 'cms', '-D', '-i', str(path)], stderr=subprocess.DEVNULL,
    )
    return plistlib.loads(data)

def aware(value):
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)

def profile_covers(profile, bundle_id):
    entitlements = profile.get('Entitlements') or {}
    if entitlements.get('application-identifier') != f'{team}.{bundle_id}':
        return False
    if team not in (profile.get('TeamIdentifier') or []):
        return False
    platforms = profile.get('Platform')
    if platforms and 'iOS' not in platforms:
        return False
    expires = profile.get('ExpirationDate')
    if isinstance(expires, datetime) and aware(expires) <= datetime.now(timezone.utc):
        return False
    return True

def newest_profile(bundle_id):
    found = []
    home = Path.home()
    directories = [
        home / 'Library/Developer/Xcode/UserData/Provisioning Profiles',
        home / 'Library/MobileDevice/Provisioning Profiles',
    ]
    for directory in directories:
        if not directory.is_dir():
            continue
        for path in directory.glob('*.mobileprovision'):
            try:
                profile = decode_profile(path)
            except (subprocess.CalledProcessError, plistlib.InvalidFileException):
                continue
            if not profile_covers(profile, bundle_id):
                continue
            created = profile.get('CreationDate')
            stamp = aware(created) if isinstance(created, datetime) else datetime.min.replace(tzinfo=timezone.utc)
            found.append((stamp, path, profile))
    if not found:
        return None
    found.sort(key=lambda item: item[0])
    return found[-1]

def granted(value, allowed):
    if isinstance(value, list):
        return isinstance(allowed, list) and all(item in allowed for item in value)
    return value == allowed

for (bundle, source, name), info in zip(bundles, infos):
    if not (bundle / info['CFBundleExecutable']).is_file():
        raise SystemExit(f'Missing executable in {bundle.name}.')
    network = plistlib.loads(source.read_bytes()).get(
        'com.apple.developer.networking.networkextension', [],
    )
    if 'packet-tunnel-provider' not in network:
        raise SystemExit(f'Missing packet tunnel capability in {source.name}.')
    entitlements = {
        'application-identifier': f'{team}.{info["CFBundleIdentifier"]}',
        'com.apple.developer.team-identifier': team,
        'com.apple.developer.networking.networkextension': ['packet-tunnel-provider'],
        'com.apple.security.application-groups': [app_group],
    }
    if identity != '-':
        provision = bundle / 'embedded.mobileprovision'
        if provision.is_file():
            profile = decode_profile(provision)
            if not profile_covers(profile, info['CFBundleIdentifier']):
                raise SystemExit(
                    f'embedded.mobileprovision in {bundle.name} does not match '
                    f'{team}.{info["CFBundleIdentifier"]}.',
                )
            print(f'{name}: kept embedded.mobileprovision')
        else:
            match = newest_profile(info['CFBundleIdentifier'])
            if match is None:
                raise SystemExit(
                    f'No provisioning profile for {team}.{info["CFBundleIdentifier"]}. '
                    'Run a signed xcodebuild with -allowProvisioningUpdates, '
                    'or pass FLCLASH_SIGN_IDENTITY=- for ad hoc signing.',
                )
            _, path, profile = match
            shutil.copyfile(path, provision)
            print(f'{name}: embedded profile {profile.get("Name", path.name)}')
        allowed = profile.get('Entitlements') or {}
        for key, value in entitlements.items():
            if key not in allowed or not granted(value, allowed[key]):
                raise SystemExit(
                    f'{name} entitlements are not granted by the provisioning profile ({key}).',
                )
    (stage / f'{name}-entitlements.plist').write_bytes(plistlib.dumps(entitlements))
    print(f'{name}: {info["CFBundleIdentifier"]}, team: {team}, App Group: {app_group}')
PY

while IFS= read -r -d '' task_library; do
  codesign --force --sign "$task_identity" --timestamp=none "$task_library"
done < <(find "$task_app" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0)
codesign --force --sign "$task_identity" --timestamp=none --generate-entitlement-der \
  --entitlements "$task_stage/tunnel-entitlements.plist" "$task_extension"
codesign --force --sign "$task_identity" --timestamp=none --generate-entitlement-der \
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
