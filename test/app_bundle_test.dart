// The identity of a chosen application, read from its bundle: what `open -b`
// needs, and what the Settings row shows.
//
// MADR 0048 stores the identifier rather than a name or a path, so every case
// where an identifier cannot be established must be REFUSED at pick time — a
// stored path or name reproduces the `open -a 'Visual Studio Code'` failure
// with the user's own choice, and fails at launch where nothing explains it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/utils/app_bundle.dart';

/// Writes a fixture bundle under [root] and returns its path. A null [plist]
/// leaves `Contents/` without an `Info.plist`.
String _bundle(Directory root, String name, {String? plist}) {
  final contents = Directory('${root.path}/$name/Contents')
    ..createSync(recursive: true);
  if (plist != null) {
    File('${contents.path}/Info.plist').writeAsStringSync(plist);
  }
  return '${root.path}/$name';
}

String _xml({String? id, String? name}) =>
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<plist version="1.0">\n<dict>\n'
    '${id == null ? '' : '\t<key>CFBundleIdentifier</key>\n\t<string>$id</string>\n'}'
    '${name == null ? '' : '\t<key>CFBundleName</key>\n\t<string>$name</string>\n'}'
    '</dict>\n</plist>\n';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('mg_app_bundle_'));
  tearDown(() => root.deleteSync(recursive: true));

  test('reads the identifier and display name from an app bundle', () {
    final path = _bundle(
      root,
      'Editor.app',
      plist: _xml(id: 'com.example.editor', name: 'Editor Pro'),
    );

    expect(
      readAppBundle(path),
      const AppBundle(bundleId: 'com.example.editor', name: 'Editor Pro'),
    );
  });

  test("falls back to the bundle's own name when CFBundleName is absent", () {
    final path = _bundle(
      root,
      'Ghostty.app',
      plist: _xml(id: 'com.mitchellh.ghostty'),
    );

    final bundle = readAppBundle(path);
    expect(bundle?.bundleId, 'com.mitchellh.ghostty');
    expect(bundle?.name, 'Ghostty', reason: 'the .app suffix is not a name');
  });

  test('a directory that is not an app bundle is refused', () {
    expect(readAppBundle(_bundle(root, 'NotAnApp')), isNull);
    expect(readAppBundle('${root.path}/never-existed.app'), isNull);
  });

  test('an Info.plist with no CFBundleIdentifier is refused', () {
    final path = _bundle(root, 'Nameless.app', plist: _xml(name: 'Nameless'));

    expect(
      readAppBundle(path),
      isNull,
      reason: 'without an identifier there is nothing `open -b` could use',
    );
  });

  test('a binary Info.plist is refused rather than guessed', () {
    final path = _bundle(root, 'Binary.app', plist: '');
    File(
      '$path/Contents/Info.plist',
    ).writeAsBytesSync(<int>[...'bplist00'.codeUnits, 0xd1, 0x01, 0x02]);

    expect(readAppBundle(path), isNull);
  });
}
