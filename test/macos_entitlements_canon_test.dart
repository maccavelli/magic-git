// The committed entitlements are what the signed app ships with, and one of
// them is a security posture rather than a preference: without
// `com.apple.security.app-sandbox` the app runs unsandboxed, and without
// `keychain-access-groups` it cannot reach the Keychain for stored secrets.
//
// `build_macos.sh --unsigned` deletes both *transiently* — it copies the file
// to a gitignored `.bak`, strips the keys with PlistBuddy, and restores from
// an EXIT trap. A build that dies between the strip and the trap leaves the
// stripped file on disk, and because the `.bak` is gitignored nothing in
// `git status` says so. Until now the only thing standing between that state
// and a commit was somebody reading the diff.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _release = 'macos/Runner/Release.entitlements';
const _debug = 'macos/Runner/DebugProfile.entitlements';

const _strippedByUnsignedBuild =
    'This is the state `build_macos.sh --unsigned` leaves behind while it '
    'runs. Seeing it here means a build died mid-run: restore '
    '$_release from $_release.bak (or `git checkout -- macos/`) before '
    'committing. Never commit the stripped file, and never relax this test.';

/// True when [key] is present and immediately followed by `<true/>` — a key
/// set to false grants nothing, so presence alone is not the contract.
bool _grants(String plist, String key) {
  final at = plist.indexOf('<key>$key</key>');
  if (at < 0) return false;
  return plist
      .substring(at)
      .replaceFirst('<key>$key</key>', '')
      .trimLeft()
      .startsWith('<true/>');
}

void main() {
  test('Release.entitlements keeps the sandbox and keychain keys', () {
    final plist = File(_release).readAsStringSync();

    expect(
      _grants(plist, 'com.apple.security.app-sandbox'),
      isTrue,
      reason: 'the release build must be sandboxed. $_strippedByUnsignedBuild',
    );
    expect(
      plist,
      contains('<key>keychain-access-groups</key>'),
      reason:
          'without this the app cannot reach the Keychain and secrets fall '
          'back to the 0600 file. $_strippedByUnsignedBuild',
    );

    // The grants the app's own features depend on. Local-repo access is
    // Finder-picker selection plus security-scoped bookmarks; dropping either
    // breaks opening a local repo at all, sandboxed.
    for (final key in const [
      'com.apple.security.network.client',
      'com.apple.security.files.user-selected.read-write',
      'com.apple.security.files.bookmarks.app-scope',
    ]) {
      expect(
        _grants(plist, key),
        isTrue,
        reason: '$key is load-bearing for a sandboxed build',
      );
    }
  });

  test('DebugProfile.entitlements keeps the sandbox', () {
    // Not what ships, but a debug build outside the sandbox hides sandbox
    // bugs until release — exactly when they are most expensive.
    expect(
      _grants(
        File(_debug).readAsStringSync(),
        'com.apple.security.app-sandbox',
      ),
      isTrue,
    );
  });

  test('no leftover entitlements backup', () {
    // Gitignored, so it never appears in `git status`. Its presence means a
    // build is in flight or died; in the second case the test above is
    // already failing and this says why.
    expect(
      File('$_release.bak').existsSync(),
      isFalse,
      reason:
          'A build is running, or died and left $_release stripped. '
          '$_strippedByUnsignedBuild',
    );
  });
}
