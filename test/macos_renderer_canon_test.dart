// The renderer is a declared property of the app, not an engine default
// (0063-MADR-adopt-impeller-renderer-on-macos.md). Flutter 3.47 made Impeller
// the macOS default, but a default can move again in any upgrade, and a stray
// edit to Info.plist would change the renderer with no other check noticing:
// `flutter test` renders with software Skia regardless of this key, so no
// widget test or golden can see which renderer the shipped app uses.
//
// `FLTEnableImpeller` must therefore appear exactly once, outside any XML
// comment, set to `<true/>`. Rolling back to Skia is a deliberate edit to BOTH
// Info.plist and this test, per the MADR's rollback clause.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _infoPlist = 'macos/Runner/Info.plist';
const _key = 'FLTEnableImpeller';

/// Why [plist] does not declare Impeller, or null when it does.
///
/// String matching, not an XML parser, for the same reason as
/// `macos_entitlements_canon_test.dart`: this suite runs on every platform and
/// `PlistBuddy` is macOS-only. Comments are stripped first so a commented-out
/// key never counts as a declaration.
String? _impellerDeclarationProblem(String plist) {
  final live = plist.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
  final values = RegExp(
    '<key>$_key</key>\\s*(<[^>]+>)',
  ).allMatches(live).map((m) => m[1]!).toList();
  if (values.isEmpty) return '$_key is not declared';
  if (values.length > 1) return '$_key is declared ${values.length} times';
  final value = values.single;
  if (!RegExp(r'^<true\s*/>$').hasMatch(value)) {
    return '$_key is $value, not <true/>';
  }
  return null;
}

String _plist(String body) =>
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<plist version="1.0">\n<dict>\n$body</dict>\n</plist>\n';

void main() {
  test('Info.plist declares FLTEnableImpeller = true exactly once', () {
    final plist = File(_infoPlist).readAsStringSync();
    expect(_impellerDeclarationProblem(plist), isNull);
  });

  group('the declaration check', () {
    test('accepts one live <true/>', () {
      expect(
        _impellerDeclarationProblem(
          _plist('\t<key>FLTEnableImpeller</key>\n\t<true/>\n'),
        ),
        isNull,
      );
    });

    test('rejects a missing key', () {
      expect(
        _impellerDeclarationProblem(_plist('')),
        'FLTEnableImpeller is not declared',
      );
    });

    test('rejects the Skia opt-out', () {
      expect(
        _impellerDeclarationProblem(
          _plist('\t<key>FLTEnableImpeller</key>\n\t<false/>\n'),
        ),
        'FLTEnableImpeller is <false/>, not <true/>',
      );
    });

    test('rejects a duplicate declaration', () {
      expect(
        _impellerDeclarationProblem(
          _plist(
            '\t<key>FLTEnableImpeller</key>\n\t<true/>\n'
            '\t<key>FLTEnableImpeller</key>\n\t<false/>\n',
          ),
        ),
        'FLTEnableImpeller is declared 2 times',
      );
    });

    test('ignores a key that only appears inside a comment', () {
      expect(
        _impellerDeclarationProblem(
          _plist('\t<!-- <key>FLTEnableImpeller</key><true/> -->\n'),
        ),
        'FLTEnableImpeller is not declared',
      );
    });
  });
}
