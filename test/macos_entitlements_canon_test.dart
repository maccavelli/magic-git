// The committed entitlements are what the signed app ships with, and one of
// them is a security posture rather than a preference: without
// `com.apple.security.app-sandbox` the app runs unsandboxed, and without
// `keychain-access-groups` it cannot reach the Keychain for stored secrets.
//
// `Release.entitlements` is never modified by any build. `build_macos.sh
// --unsigned` selects a SECOND tracked file — `Release-unsigned.entitlements`
// — via an xcconfig variable instead (MADR 0042); nothing strips keys from a
// signing input while Xcode reads it, so there is no window in which the
// committed file can be caught mid-mutation. `Release-unsigned.entitlements`
// is meant to differ from `Release.entitlements` by exactly two keys, and the
// second test below enforces that as a SET DIFFERENCE rather than a hardcoded
// list — a hardcoded list would silently ignore a third entitlement added to
// one file and not the other, which is the drift this guard exists to catch.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _release = 'macos/Runner/Release.entitlements';
const _unsigned = 'macos/Runner/Release-unsigned.entitlements';
const _debug = 'macos/Runner/DebugProfile.entitlements';

/// The two keys `Release-unsigned.entitlements` must omit and
/// `Release.entitlements` must grant. `keychain-access-groups` needs a signing
/// certificate an ad-hoc build has not got; `app-sandbox` is removed so `$HOME`
/// is the real home directory and the 0600 credentials fallback lands in
/// `~/.config/magic_git/` rather than inside an app container.
const _signedOnlyKeys = {
  'com.apple.security.app-sandbox',
  'keychain-access-groups',
};

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

/// Every entitlement key name present in [plist], in document order.
///
/// String matching, not an XML parser: this suite runs on every platform
/// (AGENTS.md), and `PlistBuddy` is macOS-only. `<key>` is never itself an
/// entitlement's value in any file this test reads, so a plain regex is exact
/// here without needing a real plist parser.
List<String> _keyNames(String plist) =>
    RegExp(r'<key>([^<]+)</key>').allMatches(plist).map((m) => m[1]!).toList();

/// The single XML element immediately after `<key>[key]</key>` — `<true/>`,
/// `<false/>`, `<array/>`, or a multi-line `<array>…</array>`. Used to compare
/// a grant common to two files by its actual value, not merely by its
/// presence.
String _valueOf(String plist, String key) {
  final at = plist.indexOf('<key>$key</key>');
  if (at < 0) return '';
  final after = plist.substring(at + '<key>$key</key>'.length).trimLeft();
  final selfClosing = RegExp(r'^<(\w+)\s*/>').firstMatch(after);
  if (selfClosing != null) return selfClosing[0]!;
  final open = RegExp(r'^<(\w+)>').firstMatch(after);
  if (open == null) return '';
  final tag = open[1]!;
  final end = after.indexOf('</$tag>');
  return end < 0 ? '' : after.substring(0, end + '</$tag>'.length);
}

void main() {
  test('Release.entitlements keeps the sandbox and keychain keys', () {
    final plist = File(_release).readAsStringSync();

    expect(
      _grants(plist, 'com.apple.security.app-sandbox'),
      isTrue,
      reason: 'the release build must be sandboxed',
    );
    expect(
      plist,
      contains('<key>keychain-access-groups</key>'),
      reason:
          'without this the app cannot reach the Keychain and secrets fall '
          'back to the 0600 file',
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

  test('Release-unsigned.entitlements is Release.entitlements minus exactly '
      'the sandbox and keychain keys', () {
    final signed = File(_release).readAsStringSync();
    final unsigned = File(_unsigned).readAsStringSync();

    final signedKeys = _keyNames(signed).toSet();
    final unsignedKeys = _keyNames(unsigned).toSet();

    expect(
      signedKeys.difference(unsignedKeys),
      _signedOnlyKeys,
      reason:
          'the unsigned file must be missing EXACTLY these two keys — not '
          'more (an accidentally-dropped grant breaks the unsigned build) '
          'and not fewer (a key that should require signing leaking into '
          'the ad-hoc entitlements)',
    );
    expect(
      unsignedKeys.difference(signedKeys),
      isEmpty,
      reason:
          'the unsigned file must not grant anything the signed file does '
          'not — it is a subset, never a superset',
    );

    // Every grant the two files share must be identical in VALUE, not only
    // in name — a key present in both with a different value is drift this
    // set-difference alone cannot see.
    for (final key in unsignedKeys) {
      expect(
        _valueOf(unsigned, key),
        _valueOf(signed, key),
        reason: '$key must carry the same value in both files',
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
}
