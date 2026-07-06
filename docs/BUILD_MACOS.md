# Building the macOS `.app`

A macOS app **cannot be cross-compiled from Linux** — Flutter's macOS target
calls `xcodebuild`, so the build must run on a Mac. `build_macos.sh` makes that
as light as possible: it vendors a throwaway Flutter SDK (no permanent
Flutter/Dart install) and produces a distributable `.app`.

## Prerequisites (on the Mac, unavoidable for any macOS build)

- **Xcode** — the macOS compiler + signer. Install from the App Store, then:
  ```sh
  sudo xcodebuild -runFirstLaunch
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  ```
- **CocoaPods** — links the native plugins (secure storage, path provider, …):
  ```sh
  sudo gem install cocoapods    # or: brew install cocoapods
  ```

Flutter/Dart are **not** required system-wide — the script fetches a pinned SDK
into `./.flutter-sdk` (git-ignored, delete when done).

## Build

Pick one, depending on whether you have an Apple ID for signing:

```sh
cd scripts/dart/remote-magic-git

# No Apple ID (fastest, for E2E). Builds ad-hoc; "Save connection" won't persist.
./build_macos.sh --unsigned

# — or — with signing (Keychain "Save connection" works). Requires a one-time
# Xcode step first: open macos/Runner.xcworkspace → Runner target → Signing &
# Capabilities → "Automatically manage signing" → your Apple ID (Personal Team).
./build_macos.sh
```

**Why the choice matters:** the app carries a `keychain-access-groups`
entitlement (for secure profile storage). That entitlement *requires a signing
certificate*, so a plain unsigned build fails with:
`"Runner" has entitlements that require signing with a development certificate`.
`--unsigned` temporarily removes that entitlement (and restores it after the
build) so no certificate is needed.

First run clones Flutter and runs `pod install`, so it's slow (a few minutes);
later runs are fast. Output: `RemoteMagicGit-macos.zip`.

## Run (unsigned build → clear Gatekeeper first)

Install with the script (recommended — replaces any prior install, including the
legacy `remote_magic_git.app` bundle from before the display-name change):

```sh
./build_macos.sh --unsigned --install
open ~/Applications/Magic\ Git.app
```

Or extract manually with **`ditto`**, not `unzip` — the archive is made with
`ditto`, and using the `unzip` CLI (or double-clicking the zip in Finder) spills
macOS metadata sidecars (`__MACOSX`/`._*`) that show up as a second, broken icon.

```sh
rm -rf ~/Applications/remote_magic_git.app ~/Applications/Magic\ Git.app
ditto -x -k RemoteMagicGit-macos.zip ~/Applications/
xattr -dr com.apple.quarantine ~/Applications/Magic\ Git.app
open ~/Applications/Magic\ Git.app
```

## Notes

- **Unsigned**: this is an ad-hoc build for personal use. Gatekeeper blocks it
  until you clear the quarantine attribute (above), or right-click → Open once.
- **Credential storage**: "Save connection" prefers the macOS Keychain, which
  needs a proper signature. On an `--unsigned` build the Keychain is
  unavailable, so secrets **fall back to a `0600` dotfile** at
  `~/.remote_magic_git_credentials.json` (owner-only; plaintext, same model as
  glab/git credential files). To make this land in your *real* home dir,
  `--unsigned` also strips the app-sandbox entitlement. A signed build uses the
  Keychain and never writes the dotfile.
- **Security note**: the fallback dotfile is plaintext protected only by file
  permissions. Delete it (`rm ~/.remote_magic_git_credentials.json`) to purge
  stored secrets, or use a signed build for Keychain-backed storage.
- To sign properly (so Keychain works and Gatekeeper is happy), open
  `macos/Runner.xcworkspace` in Xcode, set a Development Team under Signing,
  and `flutter build macos --release` — or archive/notarize for distribution.
- **Clean up**: `rm -rf .flutter-sdk` reclaims the vendored SDK.
