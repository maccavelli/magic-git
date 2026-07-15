#!/usr/bin/env bash
#
# build_macos.sh — build Magic Git into a distributable macOS .app.
#
# Run this ON A MAC. It vendors a throwaway Flutter SDK into ./.flutter-sdk
# (never added to your PATH permanently, safe to delete afterward), builds a
# release .app, and zips it. Flutter/Dart are NOT installed system-wide.
#
# Prerequisites that CANNOT be avoided for any macOS app build:
#   - Xcode        (the macOS compiler + signer; install from the App Store)
#   - CocoaPods    (links the native plugins; `sudo gem install cocoapods`)
#
# Usage:
#   ./build_macos.sh              signed build (needs a Development Team set in
#                                 Xcode → Signing; Keychain "Save connection" works)
#
#   NOTE (for later, when a Developer ID exists): before notarizing, set
#   ENABLE_HARDENED_RUNTIME = YES on the Runner target's Release config.
#   It must stay OFF while builds are ad-hoc signed — hardened-runtime
#   library validation requires matching Team IDs, and an ad-hoc signature
#   has none, so dyld refuses to load the embedded FlutterMacOS.framework
#   ("different Team IDs") and the app dies at launch.
#   ./build_macos.sh --unsigned   no Apple ID needed: temporarily removes the
#                                 keychain-access-groups entitlement and builds
#                                 ad-hoc. "Save connection" still persists — the
#                                 Keychain is unreachable unsigned, so secrets
#                                 fall back to ~/.config/magic_git/credentials.json
#                                 (0600). The entitlement file is restored after.
#   ./build_macos.sh --install    build, then replace any prior install in
#                                 ~/Applications (removes legacy bundle names too)
#
# Output:  ./RemoteMagicGit-macos.zip

set -euo pipefail

FLUTTER_VERSION="3.44.6"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_DIR="$SCRIPT_DIR/.flutter-sdk"
OUT_ZIP="$SCRIPT_DIR/RemoteMagicGit-macos.zip"
APP_INFO="$SCRIPT_DIR/macos/Runner/Configs/AppInfo.xcconfig"
RELEASE_DIR="$SCRIPT_DIR/build/macos/Build/Products/Release"
APPS_DIR="${HOME}/Applications"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# Prior PRODUCT_NAME values that may still be sitting in ~/Applications.
readonly LEGACY_APP_BUNDLES=(
  "remote_magic_git.app"
)

UNSIGNED=0
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --unsigned) UNSIGNED=1 ;;
    --install) INSTALL=1 ;;
    *)
      die "Unknown option: $arg (supported: --unsigned, --install)"
      ;;
  esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }

read_product_name() {
  local line
  [[ -f "$APP_INFO" ]] || die "Missing $APP_INFO"
  line="$(grep '^PRODUCT_NAME' "$APP_INFO")"
  # PRODUCT_NAME = Magic Git
  printf '%s' "${line#*=}" | xargs
}

remove_app_bundles() {
  local dir="$1"
  shift
  local name
  for name in "$@"; do
    [[ -d "${dir}/${name}" ]] || continue
    log "Removing stale bundle ${dir}/${name}"
    rm -rf "${dir}/${name}"
  done
}

# Drop a bundle from the LaunchServices database so it stops showing in
# Launchpad/Spotlight immediately, instead of lingering until the next reindex.
# Best-effort: never fail the build over it.
unregister_app() {
  local path="$1"
  [[ -x "$LSREGISTER" ]] || return 0
  "$LSREGISTER" -u "$path" >/dev/null 2>&1 || true
}

install_zip() {
  local app_name="$1"
  local target="${APPS_DIR}/${app_name}"
  mkdir -p "$APPS_DIR"
  remove_app_bundles "$APPS_DIR" "${LEGACY_APP_BUNDLES[@]}" "$app_name"
  log "Installing to $APPS_DIR (replacing any prior Magic Git install) ..."
  ditto -x -k "$OUT_ZIP" "$APPS_DIR/"
  xattr -dr com.apple.quarantine "$target" 2>/dev/null || true
  log "Installed $target"

  # The freshly-built copy under build/ is on disk AND indexed by Spotlight /
  # LaunchServices, so it shows up as a SECOND Launchpad/Finder icon alongside
  # the one we just installed (both carry the same bundle id). Remove it — it is
  # regenerated on every build — and prune its LS registration so the duplicate
  # icon disappears now rather than at the next reindex.
  if [[ -d "$APP" ]]; then
    log "Removing the build-dir copy so it doesn't show as a duplicate icon ..."
    unregister_app "$APP"
    rm -rf "$APP"
  fi
  # Make sure the surviving installed copy is the one LaunchServices knows about.
  [[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$target" >/dev/null 2>&1 || true
}

# --- Preconditions ----------------------------------------------------------
[[ "$(uname)" == "Darwin" ]] || die "This script must run on macOS (a .app cannot be built on Linux)."

xcodebuild -version >/dev/null 2>&1 || die \
  "Xcode not found. Install it from the App Store, then run:
    sudo xcodebuild -runFirstLaunch
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"

command -v pod >/dev/null 2>&1 || die \
  "CocoaPods not found. Install it, then re-run:
    sudo gem install cocoapods
  (or)
    brew install cocoapods"

PRODUCT_NAME="$(read_product_name)"
APP_NAME="${PRODUCT_NAME}.app"

# --- Vendor a throwaway Flutter SDK -----------------------------------------
if [[ ! -x "$SDK_DIR/bin/flutter" ]]; then
  log "Fetching Flutter $FLUTTER_VERSION into $SDK_DIR (one-time; delete anytime) ..."
  git clone --depth 1 --branch "$FLUTTER_VERSION" \
    https://github.com/flutter/flutter.git "$SDK_DIR"
else
  log "Reusing vendored Flutter at $SDK_DIR"
fi
export PATH="$SDK_DIR/bin:$PATH"

log "Flutter version:"
flutter --version

# --- Build ------------------------------------------------------------------
cd "$SCRIPT_DIR"

if [[ "$UNSIGNED" == "1" ]]; then
  ENT="$SCRIPT_DIR/macos/Runner/Release.entitlements"
  log "Unsigned build: removing keychain-access-groups (needs a cert) and the"
  log "app sandbox (so \$HOME is your real home for the 0600 credentials file)"
  cp "$ENT" "$ENT.bak"
  # Restore the committed entitlements no matter how the script exits.
  trap 'mv -f "$ENT.bak" "$ENT" 2>/dev/null || true' EXIT
  /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$ENT" >/dev/null 2>&1 || true
  # Without the sandbox, HOME points at the real home dir (not the app
  # container), so the Keychain-fallback credentials file lands where you expect
  # (~/.config/magic_git/). Secure storage still can't reach the Keychain
  # unsigned, so it uses that 0600 file — "Save connection" persists either way.
  /usr/libexec/PlistBuddy -c "Delete :com.apple.security.app-sandbox" "$ENT" >/dev/null 2>&1 || true
fi

log "Resolving dependencies ..."
flutter pub get

# Drop leftover bundles from prior PRODUCT_NAME values so Release never holds two
# distinct .app products (a common cause of duplicate Finder icons).
remove_app_bundles "$RELEASE_DIR" "${LEGACY_APP_BUNDLES[@]}" "$APP_NAME"

log "Building release $APP_NAME (runs pod install; first run is slow) ..."
flutter build macos --release

APP="${RELEASE_DIR}/${APP_NAME}"
[[ -d "$APP" ]] || die "Build did not produce $APP"

# --- Package ----------------------------------------------------------------
log "Packaging $APP"
# Strip extended attributes so the archive carries no resource-fork/metadata
# sidecars — those surface as bogus "__MACOSX"/"._" items (and a broken,
# non-launchable icon) when the zip is extracted with the `unzip` CLI.
xattr -cr "$APP" 2>/dev/null || true
rm -f "$OUT_ZIP"
ditto -c -k --keepParent "$APP" "$OUT_ZIP"

if [[ "$INSTALL" == "1" ]]; then
  install_zip "$APP_NAME"
fi

if [[ "$INSTALL" == "1" ]]; then
  app_line="  App:  ${APPS_DIR}/${APP_NAME} (installed; build-dir copy removed so only one icon shows)"
else
  app_line="  App:  ${APP}"
fi

cat <<EOF

$(printf '\033[1;32m✓ Done.\033[0m')
${app_line}
  Zip:  $OUT_ZIP

Install (one icon — removes legacy remote_magic_git.app AND the build-dir copy):
  ./build_macos.sh --install
  # or, after a plain build (delete the build-dir copy too, or it becomes a
  # second Launchpad icon — Spotlight indexes apps under build/ as well):
  rm -rf "$APPS_DIR/remote_magic_git.app" "$APPS_DIR/$APP_NAME" "$APP"
  ditto -x -k "$OUT_ZIP" "$APPS_DIR/"
  xattr -dr com.apple.quarantine "$APPS_DIR/$APP_NAME"
  open "$APPS_DIR/$APP_NAME"

Do NOT use the unzip CLI or double-click the zip in Finder — both can leave
__MACOSX/._* sidecars that show up as a second, broken icon.

Note: on an unsigned build the Keychain is unreachable, so "Save connection"
persists secrets to ~/.config/magic_git/credentials.json (0600) instead. Full
functionality is preserved; a signed build uses the Keychain automatically.

To reclaim disk when finished, delete the vendored SDK:
  rm -rf "$SDK_DIR"
EOF