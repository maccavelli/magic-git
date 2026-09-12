// Source files must be text, byte for byte.
//
// One raw NUL byte makes `grep`, `rg`, IDE search and GitHub's code view treat
// an entire file as binary — and they then report **zero matches, silently**,
// with no error to notice. Nothing about that failure suggests the tool simply
// refused to look.
//
// It has already cost this project three times. `AGENTS.md` carried a standing
// gotcha for `app_providers.dart`; an investigation on 2026-09-12 searched
// `git_porcelain_parser.dart` for a class it plainly contains and was told it
// was absent; and `recent_repos_store.dart` was carrying the same hazard with
// nobody aware of it.
//
// U+0000 inside a string is written `\u0000`, which compiles to exactly the
// same bytes at runtime — only the SOURCE stops being binary. So a raw NUL in a
// `.dart` file buys nothing at all.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Where source lives. `build/` and `.dart_tool/` are deliberately absent:
/// generated output is not ours to hold to this.
const _roots = ['lib', 'test', 'tool', 'integration_test', 'scripts'];

void main() {
  test('no source file contains a raw NUL byte', () {
    final offenders = <String>[];

    for (final root in _roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final nulls = entity.readAsBytesSync().where((b) => b == 0).length;
        if (nulls > 0) offenders.add('${entity.path} ($nulls)');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These files are binary to every search tool, which reports no '
          'matches rather than an error. Write the NUL as the escape '
          r"'\u0000'"
          ' — identical at runtime, and the file stays searchable.',
    );
  });
}
