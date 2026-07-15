#!/bin/sh
# Stamps the built app's Info.plist with a version derived from git:
#
#   <newest v-tag reachable from HEAD, without the leading v>.<commits since that tag>
#
# e.g. tag v1.2.22 with 5 commits on top -> 1.2.22.5. Bumping the version is
# just `git tag v1.2.23` — nothing in the repo needs editing.
#
# Runs as the Runner target's last build phase, so it rewrites the PROCESSED
# Info.plist inside the product bundle (before code signing, which happens
# after all build phases). The checked-in Runner/Info.plist keeps a 0.0.0
# placeholder on purpose: an About panel showing 0.0.0 means this stamp did
# not run — a loud signal, instead of a stale hardcoded number that looks real.
set -eu

REPO="$SRCROOT/.."
GIT=/usr/bin/git

TAG=$("$GIT" -C "$REPO" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null) || {
  echo "error: no version tag reachable from HEAD — create one, e.g.: git tag -a v1.2.22 -m v1.2.22" >&2
  exit 1
}
BASE=${TAG#v}
COUNT=$("$GIT" -C "$REPO" rev-list --count "$TAG..HEAD")
VERSION="$BASE.$COUNT"

PLIST="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST"
echo "note: stamped version $VERSION into $INFOPLIST_PATH"
