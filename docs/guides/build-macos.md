# Building the macOS `.app`

A macOS app **cannot be cross-compiled from Linux**. Flutter's macOS target
calls `xcodebuild`, so the build must run on a Mac. `build_macos.sh` keeps that
as light as possible: it uses a Flutter SDK at exactly the pinned version
(vendoring one if needed), picks the right entitlements for a signed or unsigned
build, and produces a distributable `.app` and zip.

Always build through the script. A plain `flutter build macos` skips the
entitlement selection described below; see
[Signing for real and notarizing](#signing-for-real-and-notarizing).

## Prerequisites

- **Xcode** — the macOS compiler and signer. Install it from the App Store, then:
  ```sh
  sudo xcodebuild -runFirstLaunch
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  ```
- **CocoaPods** — links the native plugins (secure storage, path provider, …):
  ```sh
  sudo gem install cocoapods    # or: brew install cocoapods
  ```

The script checks for both and stops with these instructions if either is missing.

### The Flutter pin

`build_macos.sh` sets `FLUTTER_VERSION` (currently **3.47.2**). That is the SDK the
app ships on. The script:

1. uses a `flutter` already on your `PATH` **only if** its tag is exactly that
   version;
2. otherwise clones that tag into `./.flutter-sdk` (git-ignored, never added to
   your `PATH`), and re-fetches it if the vendored copy is a different version.

The exact version matters. Flutter pins several transitive packages, so a
different SDK rewrites `pubspec.lock` and fails the golden tests on antialiasing
alone. Before working in the repository with your own `flutter`, check that it
agrees:

```sh
flutter --version | head -1          # must match FLUTTER_VERSION in build_macos.sh
flutter pub get --enforce-lockfile   # must say "Got dependencies!"
```

If they disagree, use `./.flutter-sdk/bin/flutter`, which the script fetches.

## Build

From the repository root, pick one:

```sh
# No signing certificate needed — the standard development loop.
./build_macos.sh --unsigned

# Signed. Needs a one-time Xcode step first: open macos/Runner.xcworkspace →
# Runner target → Signing & Capabilities → "Automatically manage signing" →
# your Apple ID (Personal Team).
./build_macos.sh
```

The first run may clone Flutter and install the CocoaPods dependencies, so it is
slow (a few minutes). Later runs are fast. An unknown option stops the script with
`Unknown option: … (supported: --unsigned, --install)`.

### How the entitlements are chosen

The app ships with `macos/Runner/Release.entitlements`, which includes the app
sandbox and `keychain-access-groups` (for storing secrets in the Keychain). That
entitlement **requires a signing certificate**, so an ad-hoc build that used it
would fail with `"Runner" has entitlements that require signing with a
development certificate`.

No entitlements file is ever edited. There are two tracked files, and the build
picks one:

| Build | Signs with | Differs by |
|---|---|---|
| `./build_macos.sh` | `Runner/Release.entitlements` | — |
| `./build_macos.sh --unsigned` | `Runner/Release-unsigned.entitlements` | no app sandbox, no `keychain-access-groups` |

The selection is the xcconfig variable `MG_RELEASE_ENTITLEMENTS`.
`macos/Runner/Configs/AppInfo.xcconfig` defaults it to the signed file, then
optionally includes `Configs/Local.xcconfig`. The script **rewrites
`Local.xcconfig` on every run, in both modes**, so a signed build after an
unsigned one never inherits the unsigned selection. `Local.xcconfig` is
generated and git-ignored — never commit it. `test/macos_entitlements_canon_test.dart`
pins both entitlements files and the relationship between them.

## Credential storage

"Save connection" keeps passwords, private keys and tokens in secure storage:

- **Signed build** — the macOS Keychain. Nothing is written to disk by Magic Git.
- **Unsigned build** — the Keychain is unreachable without a signature, so
  secrets fall back to `~/.config/magic_git/credentials.json`, written `0600`
  (owner-only). Saved connections **do** persist. The unsigned entitlements have
  no app sandbox, so this lands in your real home folder rather than an app
  container.

The fallback file is plaintext protected only by file permissions — the same
model as git and glab credential files. Delete it
(`rm ~/.config/magic_git/credentials.json`) to purge stored secrets, or use a
signed build.

## Install

```sh
./build_macos.sh --unsigned --install    # or: ./build_macos.sh --install
open ~/Applications/Magic\ Git.app
```

`--install` works for both signed and unsigned builds. After building, it:

1. removes any previous install in `~/Applications`, including the legacy
   `remote_magic_git.app` bundle from before the display-name change;
2. extracts the new zip there with `ditto` and clears the quarantine attribute;
3. deletes the build-directory copy (`build/macos/Build/Products/Release/Magic Git.app`)
   and refreshes LaunchServices. Spotlight indexes apps under `build/` too, so
   leaving that copy shows a second Launchpad icon.

To install by hand instead, use **`ditto`**, not `unzip`. The archive is made
with `ditto`, and the `unzip` CLI (or double-clicking the zip in Finder) spills
`__MACOSX`/`._*` sidecars that show up as a second, broken icon:

```sh
rm -rf ~/Applications/remote_magic_git.app ~/Applications/Magic\ Git.app \
  "build/macos/Build/Products/Release/Magic Git.app"
ditto -x -k RemoteMagicGit-macos.zip ~/Applications/
xattr -dr com.apple.quarantine ~/Applications/Magic\ Git.app
open ~/Applications/Magic\ Git.app
```

An unsigned build is ad-hoc signed. Gatekeeper blocks it until the quarantine
attribute is cleared (above; `--install` does this for you) or you right-click →
Open once.

## Output and targets

| What | Where |
|---|---|
| App bundle | `build/macos/Build/Products/Release/Magic Git.app` (removed by `--install`) |
| Distributable zip | `RemoteMagicGit-macos.zip` in the repository root |
| Installed app (`--install`) | `~/Applications/Magic Git.app` |

The app targets **macOS 12.0** or later (`MACOSX_DEPLOYMENT_TARGET`).

## Signing for real and notarizing

- To sign with your team, set a Development Team under Signing in
  `macos/Runner.xcworkspace`, then build with **`./build_macos.sh`**. Do not run
  a plain `flutter build macos --release` instead. It does not rewrite
  `Local.xcconfig`, so after any `--unsigned` run it would still sign with
  `Release-unsigned.entitlements`, and produce a signed app **without the
  sandbox or Keychain access**.
- Before notarizing for distribution, set `ENABLE_HARDENED_RUNTIME = YES` on the
  Runner target's Release configuration. It must stay **off** for ad-hoc builds.
  Hardened-runtime library validation requires matching Team IDs, and an ad-hoc
  signature has none, so dyld refuses to load the embedded
  `FlutterMacOS.framework` ("different Team IDs") and the app dies at launch.

## Running the Xcode unit tests without a certificate

The `RunnerTests` target (native Swift tests, such as the Help search tests) is
built with the Debug configuration. That configuration signs with
`DebugProfile.entitlements`, which also includes `keychain-access-groups`. On a
machine with no development team, select the tracked unsigned variant for the
test run only:

```sh
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner \
  -destination 'platform=macOS' \
  MG_DEBUG_ENTITLEMENTS=Runner/DebugProfile-unsigned.entitlements
```

`MG_DEBUG_ENTITLEMENTS` defaults to `Runner/DebugProfile.entitlements` in
`AppInfo.xcconfig`, so ordinary Debug builds are unchanged. The unsigned variant
keeps the sandbox and drops only the Keychain entitlement.

## Troubleshooting

- **`"Runner" has entitlements that require signing with a development certificate`**
  — you built without the script, or ran Xcode's tests without the
  `MG_DEBUG_ENTITLEMENTS` override above. Use `./build_macos.sh --unsigned`.
- **"Entitlements file … was modified during the build"** — something edited a
  tracked entitlements file while Xcode was signing from it. Nothing in this
  repository does that any more (MADR 0042). Check `git diff macos/Runner/*.entitlements`
  and find what changed it.
- **Gatekeeper says the app is damaged or can't be opened** — clear quarantine:
  `xattr -dr com.apple.quarantine ~/Applications/Magic\ Git.app`.
- **Two Magic Git icons in Launchpad** — a leftover build-directory copy or a
  legacy bundle. Re-run with `--install`, or remove both by hand (see Install).
- **`pubspec.lock` changes after every command, or goldens fail** — a Flutter
  other than the pin is on your `PATH`. See [The Flutter pin](#the-flutter-pin).

## Clean up

`rm -rf .flutter-sdk` reclaims the vendored SDK (about 1.7 GB). The script
fetches it again when needed.
