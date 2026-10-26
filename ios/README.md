# iOS

The Runner uses the existing Flutter UI and mihomo method protocol. While VPN is
stopped, the application hosts Core for profile parsing and validation. Starting
VPN drains outstanding calls, shuts down the application's Core, and starts Core
inside `PacketTunnel.appex`. Stopping waits for the extension to disconnect before
restoring the local Core. Profiles, provider caches, temporary inputs and response
spill files live in the App Group container. The extension runs without Flutter.

## Build an unsigned IPA

Use the repository's Flutter 3.47.6 / Dart 3.13 SDK, Go 1.27+, Xcode with the iOS
SDK, CocoaPods, and the pinned Rust toolchain from
`plugins/rust_api/rust/rust-toolchain.toml`.

```sh
./tool/build_ios_unsigned.sh
# Or select an SDK without changing the default:
FLUTTER_BIN=/path/to/flutter/bin/flutter ./tool/build_ios_unsigned.sh
```

The build generates `ios/Frameworks/FlClashCore.xcframework` with the pinned
gomobile dependency and embeds `PacketTunnel.appex`. The final archive is
`build/ios/ipa/FlClash-unsigned.ipa`. For a simulator build, the Core build phase
also generates simulator slices; a simulator cannot validate device VPN routing.
Optional high-memory mihomo EasyTier, ZeroTier and Tailscale integrations are
excluded from the iOS Core to fit the packet tunnel memory budget.

## Sign and run on a device

An unsigned IPA is a build artifact. Normal iOS installation and VPN operation
require signing **both** Runner and PacketTunnel with profiles that contain the
Network Extension and App Group entitlements.

Create an ignored `ios/Signing.xcconfig`:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
FLCLASH_BUNDLE_ID = your.unique.flclash
FLCLASH_APP_GROUP = group.your.unique.flclash
```

Register the application ID, the `.PacketTunnel` extension ID and their common
App Group in the Apple developer account. Run `./tool/build_ios_core.sh`,
`flutter pub get` and `pod install` (from `ios/`). Open `ios/Runner.xcworkspace`,
select the Runner scheme and a device, and
build with signing. The first VPN start triggers iOS's VPN permission prompt.

## Install with TrollStore

On a device already running TrollStore, Apple developer certificates and
provisioning profiles are unnecessary. iOS 16.4 is within TrollStore's supported
range and above this application's iOS 15 minimum.

After building the unsigned IPA, prepare a separate package on macOS:

```sh
./tool/package_ios_trollstore.sh
# Or use another unsigned build:
./tool/package_ios_trollstore.sh /path/to/FlClash-unsigned.ipa
```

The output is `build/ios/ipa/FlClash-TrollStore.ipa`. The script embeds the
Network Extension and matching App Group entitlements into both Runner and
PacketTunnel using ad hoc signatures, with the `TROLLTROLL` identity prefix used
by TrollStore. It reads bundle IDs and the shared group from the built bundles,
verifies nested signatures and embedded entitlements, and preserves the input
IPA. No signing certificate or `ldid` installation is needed on the Mac.

Open the resulting IPA in TrollStore to install it. Approve iOS's VPN permission
prompt on the first connection. TrollStore performs the device-side signing and
container registration. Its [official instructions](https://github.com/opa334/TrollStore#features)
require entitlements to be present in binaries before installation; the raw
`--no-codesign` build does not embed the project's entitlement files.

Packaging and entitlement verification do not verify VPN execution. A physical
device must still validate App Group access, tunnel launch and routing. The same
extension memory and utun compatibility limits below apply.

## Validation boundaries

- Verify subscription import, proxy selection, traffic, DNS, IPv4/IPv6, Wi-Fi to
  cellular handoff, screen lock, foreground/background transitions, external VPN
  stop and repeated start/stop on a signed physical device.
- iOS's extension memory ceiling is much lower than a desktop process. Large
  rule sets and profiles need device memory testing; the Go memory limit is a
  collection target, not a guarantee against jetsam.
- The integration uses the existing sing-tun descriptor path. Obtaining utun via
  `NEPacketTunnelFlow`'s `socket.fileDescriptor` is an undocumented compatibility
  dependency, isolated in `PacketTunnelProvider.tunnelDescriptor()`. This is a
  practical shortcut used by existing open-source clients, not a guarantee of
  compatibility with future iOS versions or App Review.
- Android package exclusions, bypass permission, Quick Settings tiles and
  always-on service controls are not iOS capabilities. Per-app VPN requires
  managed-device configuration and is outside this integration.

Reference implementations examined: [ClashMi](https://github.com/KaringX/clashmi)
and [sing-box-for-apple](https://github.com/SagerNet/sing-box-for-apple). This
integration reuses FlClash's existing GPL Core rather than adding another engine.
Apple deployment requirements: [TN3134](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment).
