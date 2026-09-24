#!/usr/bin/env bash
#
# devenv.sh — bootstrap a Mac to build and test Magic Git.
#
# Checks every tool the sources need and installs what is missing where that
# is safe to do unattended (Homebrew formulae, the pinned Flutter SDK, Dart
# packages). Steps that need an administrator password — selecting Xcode,
# accepting its licence — are never run for you: the script prints the exact
# command and counts the step as not done.
#
# Usage:
#   ./devenv.sh              check, and install what is missing
#   ./devenv.sh --check      report only; changes nothing
#   ./devenv.sh --optional   also install the optional tools (gh, glab)
#
# Exits 0 when everything required is in place, 1 otherwise. Safe to re-run.
#
# Required: macOS, Xcode (selected, licence accepted, first launch done), git
# 2.24 or newer, Flutter at the version build_macos.sh pins, and Python 3.12
# or newer (checked in depth by dependencies.py). Not CocoaPods: the plugins
# link through Swift Package Manager, which comes with Xcode.
# Optional: gh and glab — forge features on this Mac, and the live-forge tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SCRIPT="$SCRIPT_DIR/build_macos.sh"
SDK_DIR="$SCRIPT_DIR/.flutter-sdk"
FLUTTER_REPO="https://github.com/flutter/flutter.git"

MIN_GIT="2.24"      # lib/core/settings/tool_catalog.dart: --end-of-options
MIN_PYTHON="3.12"

MODE="install"
OPTIONAL=0
FAILURES=0
FLUTTER=""

usage() { sed -n '3,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

for arg in "$@"; do
  case "$arg" in
    --check) MODE="check" ;;
    --optional) OPTIONAL=1 ;;
    -h | --help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n\n' "$arg" >&2; usage >&2; exit 2 ;;
  esac
done

# --- Output -----------------------------------------------------------------

# Colour only on a terminal, so a log file or a pipe gets plain text.
if [[ -t 1 ]]; then
  BOLD=$'\033[1m' BLUE=$'\033[1;34m' GREEN=$'\033[32m' RED=$'\033[31m' RESET=$'\033[0m'
else
  BOLD='' BLUE='' GREEN='' RED='' RESET=''
fi

section() { printf '\n%s==>%s %s%s%s\n' "$BLUE" "$RESET" "$BOLD" "$1" "$RESET"; }
ok() { printf '  %sok%s    %s\n' "$GREEN" "$RESET" "$1"; }
info() { printf '  info  %s\n' "$1"; }
# fail <what is wrong> [<how to fix it>]
fail() {
  printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"
  [[ $# -lt 2 ]] || printf '        fix: %s\n' "$2"
  FAILURES=$((FAILURES + 1))
}

have() { command -v "$1" >/dev/null 2>&1; }

# The first dotted number a tool prints for --version: "gh version 2.99.0 (…)"
# and "glab 1.116.0 (…)" put it in different fields.
tool_version() {
  "$1" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true
}

# version_ge <have> <need>: numeric, dot-separated, missing parts count as 0.
version_ge() {
  local -a have_parts need_parts
  local i h n
  IFS=. read -r -a have_parts <<<"$1"
  IFS=. read -r -a need_parts <<<"$2"
  for i in 0 1 2; do
    h="${have_parts[i]:-0}"
    n="${need_parts[i]:-0}"
    h="${h%%[!0-9]*}"
    n="${n%%[!0-9]*}"
    h=$((10#${h:-0}))
    n=$((10#${n:-0}))
    ((h > n)) && return 0
    ((h < n)) && return 1
  done
  return 0
}

# brew_install <formula> <what>: install a missing tool, or say how to.
brew_install() {
  local formula="$1" what="$2"
  if [[ "$MODE" == "check" ]]; then
    fail "$what is missing" "brew install $formula (or run ./devenv.sh)"
    return
  fi
  if ! have brew; then
    fail "$what is missing, and Homebrew is needed to install it" \
      "install Homebrew from https://brew.sh, then re-run ./devenv.sh"
    return
  fi
  info "installing $formula with Homebrew ..."
  if brew install "$formula"; then
    hash -r
    ok "installed $formula"
  else
    fail "brew install $formula failed" "read the Homebrew output above"
  fi
}

# --- Steps ------------------------------------------------------------------

check_macos() {
  section "macOS"
  if [[ "$(uname -s)" != "Darwin" ]]; then
    fail "this is $(uname -s); Magic Git builds only on macOS" \
      "flutter analyze and flutter test also run elsewhere, but this script does not"
    exit 1
  fi
  ok "macOS $(sw_vers -productVersion) on $(uname -m)"
}

check_xcode() {
  section "Xcode"
  local selected
  selected="$(xcode-select -p 2>/dev/null || true)"
  if [[ -z "$selected" ]] || ! xcodebuild -version >/dev/null 2>&1; then
    if [[ "$selected" == *CommandLineTools* ]]; then
      fail "the Command Line Tools are selected, not Xcode" \
        "install Xcode from the App Store, then: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    else
      fail "Xcode is not installed" \
        "install Xcode from the App Store, then: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    fi
    return
  fi
  ok "$(xcodebuild -version | head -1) at $selected"
  if xcodebuild -license check >/dev/null 2>&1; then
    ok "Xcode licence accepted"
  else
    fail "the Xcode licence has not been accepted" "sudo xcodebuild -license accept"
  fi
  if xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    ok "Xcode first-launch setup done"
  else
    fail "Xcode's first-launch setup has not run" "sudo xcodebuild -runFirstLaunch"
  fi
}

check_homebrew() {
  section "Homebrew"
  if have brew; then
    ok "$(brew --version | head -1) at $(command -v brew)"
  elif [[ "$MODE" == "check" ]]; then
    info "Homebrew is not installed; ./devenv.sh uses it to install missing tools"
  else
    info "Homebrew is not installed; tools found missing below cannot be installed"
    info "install it from https://brew.sh (the script there asks for your password)"
  fi
}

check_git() {
  section "git"
  if ! have git; then
    brew_install git "git"
    have git || return 0
  fi
  local version
  version="$(tool_version git)"
  if version_ge "$version" "$MIN_GIT"; then
    ok "git $version at $(command -v git) (need $MIN_GIT or newer)"
  else
    fail "git $version is older than $MIN_GIT" "brew install git, and put Homebrew first on PATH"
  fi
}

# The pinned version, read from build_macos.sh so there is one source for it.
flutter_pin() {
  local line
  line="$(grep -E '^FLUTTER_VERSION="[^"]+"' "$BUILD_SCRIPT" | head -1)"
  line="${line#FLUTTER_VERSION=\"}"
  printf '%s' "${line%\"}"
}

# An SDK checkout's tag (e.g. 3.47.2), or nothing. Read with git rather than by
# running flutter, which can update itself — the same check build_macos.sh makes.
sdk_version() {
  git -C "$1" describe --tags 2>/dev/null | head -1 || true
}

path_flutter_root() {
  local bin
  have flutter || return 0
  bin="$(readlink -f "$(command -v flutter)" 2>/dev/null || true)"
  [[ -n "$bin" ]] || return 0
  (cd "$(dirname "$bin")/.." 2>/dev/null && pwd) || true
}

check_flutter() {
  section "Flutter"
  local pin root
  pin="$(flutter_pin)"
  if [[ -z "$pin" ]]; then
    fail "could not read FLUTTER_VERSION from build_macos.sh"
    return
  fi
  info "build_macos.sh pins Flutter $pin"

  root="$(path_flutter_root)"
  if [[ -n "$root" && "$(sdk_version "$root")" == "$pin" ]]; then
    ok "the flutter on PATH is $pin ($root)"
    FLUTTER="$root/bin/flutter"
    return
  fi
  if [[ -n "$root" ]]; then
    info "the flutter on PATH is ${root:+$(sdk_version "$root")} ($root), not $pin"
  fi

  if [[ -x "$SDK_DIR/bin/flutter" && "$(sdk_version "$SDK_DIR")" == "$pin" ]]; then
    ok "vendored Flutter $pin at .flutter-sdk — run it as ./.flutter-sdk/bin/flutter"
    FLUTTER="$SDK_DIR/bin/flutter"
    return
  fi
  if [[ "$MODE" == "check" ]]; then
    fail "no Flutter $pin found" "./devenv.sh (vendors it into .flutter-sdk, as build_macos.sh does)"
    return
  fi
  if [[ -e "$SDK_DIR" ]]; then
    info "vendored Flutter is $(sdk_version "$SDK_DIR"), not $pin — re-fetching"
    rm -rf "$SDK_DIR"
  fi
  info "fetching Flutter $pin into .flutter-sdk (about 1.7 GB; gitignored; delete any time) ..."
  if git clone --depth 1 --branch "$pin" "$FLUTTER_REPO" "$SDK_DIR"; then
    ok "vendored Flutter $pin at .flutter-sdk — run it as ./.flutter-sdk/bin/flutter"
    FLUTTER="$SDK_DIR/bin/flutter"
  else
    fail "could not clone Flutter $pin" "check your network, then re-run ./devenv.sh"
  fi
}

# Engine artefacts and Dart packages. Running flutter downloads and writes its
# cache, so this happens only in install mode.
prepare_flutter() {
  [[ -n "$FLUTTER" ]] || return 0
  section "Flutter artefacts and packages"
  if [[ "$MODE" == "check" ]]; then
    if [[ -f "$SCRIPT_DIR/.dart_tool/package_config.json" ]]; then
      ok "Dart packages have been fetched (.dart_tool)"
    else
      fail "Dart packages have not been fetched" "./devenv.sh (runs flutter pub get --enforce-lockfile)"
    fi
    return
  fi
  if "$FLUTTER" precache --macos; then
    ok "macOS engine artefacts cached"
  else
    fail "flutter precache --macos failed" "read the output above"
  fi
  # --enforce-lockfile: a different SDK would otherwise rewrite pubspec.lock.
  if (cd "$SCRIPT_DIR" && "$FLUTTER" pub get --enforce-lockfile); then
    ok "Dart packages match pubspec.lock"
  else
    fail "flutter pub get --enforce-lockfile failed" \
      "the SDK and pubspec.lock disagree; use the pinned SDK above"
  fi
}

python_version() {
  "$1" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null || true
}

check_python() {
  section "Python"
  local version=""
  have python3 && version="$(python_version python3)"
  if [[ -n "$version" ]] && version_ge "$version" "$MIN_PYTHON"; then
    ok "python3 $version at $(command -v python3)"
  else
    if [[ -n "$version" ]]; then
      info "python3 on PATH is $version ($(command -v python3)), older than $MIN_PYTHON"
    fi
    brew_install python3 "Python $MIN_PYTHON or newer"
    have python3 && version="$(python_version python3)"
    if [[ "$MODE" != "check" ]] && ! version_ge "${version:-0}" "$MIN_PYTHON"; then
      fail "python3 on PATH is still ${version:-missing} ($(command -v python3 || true))" \
        "put Homebrew first on PATH: eval \"\$(brew shellenv)\" in your shell profile"
      return
    fi
    [[ "$MODE" == "check" ]] && return
  fi
  if python3 "$SCRIPT_DIR/dependencies.py"; then
    ok "dependencies.py: the Python tooling can run"
  else
    fail "dependencies.py found problems" "see its report above"
  fi
}

check_optional() {
  section "Optional"
  local tool
  for tool in gh glab; do
    if have "$tool"; then
      ok "$tool $(tool_version "$tool") at $(command -v "$tool")"
    elif [[ "$OPTIONAL" == "1" && "$MODE" != "check" ]]; then
      brew_install "$tool" "$tool"
    else
      info "$tool is not installed: forge features on this Mac and the live-forge tests need it (./devenv.sh --optional)"
    fi
  done
}

main() {
  check_macos
  check_xcode
  check_homebrew
  check_git
  check_flutter
  prepare_flutter
  check_python
  check_optional

  printf '\n'
  if ((FAILURES > 0)); then
    printf '%s%d step(s) need attention.%s Fix them and re-run ./devenv.sh.\n' "$RED" "$FAILURES" "$RESET"
    exit 1
  fi
  printf '%sReady.%s Next: flutter analyze, flutter test, ./build_macos.sh --unsigned\n' "$GREEN" "$RESET"
  if [[ "$FLUTTER" == "$SDK_DIR/bin/flutter" ]]; then
    printf 'Use ./.flutter-sdk/bin/flutter wherever these say flutter.\n'
  fi
}

main
