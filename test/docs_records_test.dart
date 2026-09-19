// The documentation checker (tool/records.dart, MADR 0054) and the tree it
// guards.
//
// Two groups. "fixtures" builds a small tree per case with one planted defect
// and asserts the rule reports exactly that — so a rule that silently checks
// nothing fails here, even though the clean real tree would never notice.
// "this repository" runs the rules over the real tree and expects nothing.
//
// Tagged `integration`: the checker lists files with `git ls-files`.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/records.dart';

/// A correct tree exercising every construct the rules must tolerate: an
/// anchored link, a dead link inside a fence and inside inline code, a dead
/// `docs/` mention inside a blockquote and inside frontmatter, a MADR/PLAN
/// pair, a report and a guide, all indexed.
Map<String, String> cleanTree() => {
  'README.md': '# Project\n\nSee [the docs](docs/README.md).\n',
  'docs/README.md': [
    '# Documentation',
    '',
    '* [Architecture](architecture.md)',
    '* [Guide](guides/setup.md)',
    '* [0001 decision](decisions/0001-MADR-first.md) and '
        '[plan](decisions/0001-PLAN-first.md)',
    '* [0002 report](reports/0002-REPORT-second.md)',
    '',
  ].join('\n'),
  'docs/architecture.md': '# Architecture\n\n## Two words\n\nBody.\n',
  'docs/guides/setup.md': '# Setup\n\nBack to [the index](../README.md).\n',
  'docs/decisions/0001-MADR-first.md': [
    '---',
    'status: "accepted"',
    'verified: 2026-01-01',
    'former-path: "docs/gone.md"',
    '---',
    '',
    '# First',
    '',
    'Its [plan](0001-PLAN-first.md), and [a section](../architecture.md#two-words).',
    'Inline code is not a link: `[x](missing.md)`.',
    '',
    '```',
    '[fenced](missing.md) and docs/fenced-gone.md',
    '```',
    '',
    '> Quoted: docs/quoted-gone.md was here.',
    '',
    'See docs/architecture.md and [external](https://example.com/x.md).',
    '',
  ].join('\n'),
  'docs/decisions/0001-PLAN-first.md':
      '---\nstatus: "complete"\nverified: 2026-01-01\n---\n\n# Plan\n\n'
      '[MADR](0001-MADR-first.md)\n',
  'docs/reports/0002-REPORT-second.md':
      '---\nstatus: "partial"\nverified: 2026-01-01\n---\n\n# Report\n',
  'lib/a.dart':
      "// Described in docs/architecture.md.\nconst p = 'docs/not-a-comment.md';\n",
};

late Directory _tmp;

/// Writes [files] into a fresh `git init`ed directory and runs [rules].
List<String> run(
  Map<String, String> files, {
  List<String> rules = allRules,
  void Function(Directory root)? extra,
}) {
  final root = Directory('${_tmp.path}/repo')..createSync();
  final init = Process.runSync('git', [
    'init',
    '-q',
  ], workingDirectory: root.path);
  expect(init.exitCode, 0, reason: '${init.stderr}');
  for (final MapEntry(key: path, value: text) in files.entries) {
    File('${root.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
  }
  extra?.call(root);
  return [
    for (final f in check(root, rules: rules)) '${f.rule} ${f.path}:${f.line}',
  ];
}

Map<String, String> withFile(String path, String text) =>
    cleanTree()..[path] = text;

Map<String, String> appended(String path, String text) {
  final tree = cleanTree();
  tree[path] = '${tree[path]!}$text';
  return tree;
}

const _madr = 'docs/decisions/0001-MADR-first.md';

/// The MADR fixture is 18 lines, newline-terminated, so appended text starts
/// on line 19.
const _firstAppendedLine = 19;

void main() {
  setUp(() => _tmp = Directory.systemTemp.createTempSync('docs_records_'));
  tearDown(() => _tmp.deleteSync(recursive: true));

  group('fixtures', () {
    test('F0 a correct tree reports nothing', () {
      expect(run(cleanTree()), isEmpty);
    });

    test('F1 a relative link to a missing file', () {
      expect(run(appended(_madr, '[gone](0009-MADR-gone.md)\n')), [
        'links $_madr:$_firstAppendedLine',
      ]);
    });

    test('F2 dead links in a fence or inline code are not links', () {
      expect(
        run(appended(_madr, '```md\n[x](gone.md)\n```\nand `[y](gone.md)`\n')),
        isEmpty,
      );
      expect(run(appended(_madr, '``[z](gone.md) ` still code``\n')), isEmpty);
    });

    test('F3 a reference definition to a missing file', () {
      expect(run(appended(_madr, '[ref]: ./gone.md\n')), [
        'links $_madr:$_firstAppendedLine',
      ]);
    });

    test('F4 external targets are not checked', () {
      expect(
        run(
          appended(
            _madr,
            '[a](https://x.invalid/gone.md) [b](mailto:a@b.invalid) '
            '[c](//host.invalid/gone.md)\n',
          ),
        ),
        isEmpty,
      );
    });

    test('F5 a link inside a blockquote is still a link', () {
      expect(run(appended(_madr, '> [gone](gone.md)\n')), [
        'links $_madr:$_firstAppendedLine',
      ]);
    });

    test('F6 ignored files and symlinks are not checked', () {
      final tree = cleanTree()
        ..['.gitignore'] = 'ignored.md\n'
        ..['ignored.md'] = '[gone](gone.md)\n'
        ..['real.md'] = '[gone](gone.md)\n';
      expect(
        run(
          tree,
          extra: (root) =>
              Link('${root.path}/alias.md').createSync('${root.path}/real.md'),
        ),
        ['links real.md:1'],
      );
    });

    test('F7 an untracked file is checked before it is staged', () {
      // Nothing in a fixture is committed, so this is the untracked case; the
      // tracked case is the real tree below.
      expect(run(withFile('notes.md', 'x\n[gone](gone.md)\n')), [
        'links notes.md:2',
      ]);
    });

    test('F8 a fragment that names no heading', () {
      expect(run(appended(_madr, '[s](../architecture.md#missing)\n')), [
        'anchors $_madr:$_firstAppendedLine',
      ]);
    });

    test('F9 repeated headings are suffixed -1, -2', () {
      final tree = cleanTree()
        ..['docs/architecture.md'] = '# Arch\n\n## Same\n\n## Same\n'
        ..[_madr] = cleanTree()[_madr]!.replaceFirst(
          '../architecture.md#two-words',
          '../architecture.md#same',
        );
      expect(
        run(
          tree
            ..[_madr] =
                '${tree[_madr]!}[b](../architecture.md#same-1) '
                '[own](#first)\n',
        ),
        isEmpty,
      );
      expect(
        run(tree..[_madr] = '${tree[_madr]!}[c](../architecture.md#same-2)\n'),
        ['anchors $_madr:${_firstAppendedLine + 1}'],
      );
    });

    test('F10 GitHub slugs drop code marks and punctuation, keep letters', () {
      final tree = withFile(
        'docs/architecture.md',
        '# Arch\n\n### Phase 6a — the `docs/` move ✔\n\n'
            '## See [the *guide*](guides/setup.md)\n',
      );
      tree[_madr] =
          '${tree[_madr]!.replaceFirst('#two-words', '#phase-6a--the-docs-move-')}'
          '[s](../architecture.md#see-the-guide)\n';
      expect(run(tree), isEmpty);
    });

    test('F11 prose names a missing file by its docs/ path', () {
      expect(run(appended(_madr, 'Formerly docs/gone-away.md.\n')), [
        'paths $_madr:$_firstAppendedLine',
      ]);
    });

    test(
      'F12 fences, blockquotes and frontmatter are exempt from mentions',
      () {
        // cleanTree already carries all three; this pins them individually.
        final tree = cleanTree();
        expect(run(tree, rules: ['paths']), isEmpty);
        tree[_madr] = tree[_madr]!.replaceFirst(
          '> Quoted: docs/quoted-gone.md',
          'Unquoted: docs/quoted-gone.md',
        );
        expect(run(tree, rules: ['paths']), ['paths $_madr:16']);
      },
    );

    test('F13 a Dart comment is checked; a string literal is not', () {
      expect(
        run(
          withFile(
            'lib/b.dart',
            "// docs/gone.md\nconst s = 'docs/gone.md';\n",
          ),
        ),
        ['paths lib/b.dart:1'],
      );
    });

    test('F14 another tree\'s docs/ is not this tree\'s', () {
      expect(
        run(appended(_madr, 'In magic-git/docs/x.md and <tree>/docs/x.md.\n')),
        isEmpty,
      );
    });

    test('F15 0011 and 0012 may carry two MADRs, never three', () {
      String madr(String title) => '---\nstatus: "accepted"\n---\n# $title\n';
      final twins = cleanTree()
        ..['docs/decisions/0011-MADR-one.md'] = madr('one')
        ..['docs/decisions/0011-MADR-two.md'] = madr('two');
      expect(run(twins, rules: ['numbering']), isEmpty);
      twins['docs/decisions/0011-MADR-three.md'] = madr('three');
      expect(run(twins, rules: ['numbering']), [
        'numbering docs/decisions/0011-MADR-one.md:0',
        'numbering docs/decisions/0011-MADR-three.md:0',
        'numbering docs/decisions/0011-MADR-two.md:0',
      ]);
    });

    test('F16 any other number carries one MADR', () {
      final tree = cleanTree()
        ..['docs/decisions/0001-MADR-again.md'] =
            '---\nstatus: "accepted"\n---\n# Again\n';
      expect(run(tree, rules: ['numbering']), [
        'numbering docs/decisions/0001-MADR-again.md:0',
        'numbering $_madr:0',
      ]);
    });

    test('F17 a PLAN sits beside its MADR', () {
      final tree = cleanTree();
      tree['docs/0001-PLAN-first.md'] = tree.remove(
        'docs/decisions/0001-PLAN-first.md',
      )!;
      expect(run(tree, rules: ['numbering']), [
        'numbering docs/0001-PLAN-first.md:0',
      ]);
    });

    test('F18 the next number spans every tree in the repository', () {
      final tree = cleanTree()
        ..['redis/docs/decisions/0042-MADR-cache.md'] =
            '---\nstatus: "proposed"\n---\n# Cache\n';
      final root = Directory('${_tmp.path}/repo');
      run(tree, rules: const []);
      expect(nextNumber(root, checkedFiles(root)), '0043');
    });

    test('F19 a record without frontmatter, status: or verified:', () {
      final tree = cleanTree()
        ..['docs/decisions/0001-PLAN-first.md'] = '# Plan\n'
        ..['docs/reports/0002-REPORT-second.md'] =
            '---\nverified: 2026-01-01\n---\n# Report\n'
        ..[_madr] = cleanTree()[_madr]!.replaceFirst(
          'verified: 2026-01-01\n',
          '',
        );
      expect(run(tree, rules: ['frontmatter']), [
        'frontmatter $_madr:1',
        'frontmatter docs/decisions/0001-PLAN-first.md:1',
        'frontmatter docs/reports/0002-REPORT-second.md:1',
      ]);
    });

    test('F20 records, strays and missing files in the wrong place', () {
      final tree = cleanTree()
        ..['docs/0003-MADR-flat.md'] = '---\nstatus: "accepted"\n---\n'
        ..['docs/reports/0004-MADR-misfiled.md'] =
            '---\nstatus: "accepted"\n---\n'
        ..['docs/guides/0005-numbered.md'] = '# Numbered guide\n'
        ..['docs/notes.md'] = '# Stray\n';
      tree.remove('docs/architecture.md');
      tree[_madr] = tree[_madr]!
          .replaceFirst(', and [a section](../architecture.md#two-words)', '')
          .replaceFirst('See docs/architecture.md and ', 'See ');
      tree['docs/README.md'] = tree['docs/README.md']!.replaceFirst(
        '* [Architecture](architecture.md)\n',
        '* [flat](0003-MADR-flat.md) [misfiled](reports/0004-MADR-misfiled.md)\n',
      );
      expect(run(tree, rules: ['layout'])..sort(), [
        'layout docs/0003-MADR-flat.md:0',
        'layout docs/0003-MADR-flat.md:0',
        'layout docs/architecture.md:0',
        'layout docs/guides/0005-numbered.md:0',
        'layout docs/notes.md:0',
        'layout docs/reports/0004-MADR-misfiled.md:0',
      ]);
    });

    test('F21 an unindexed record, and a root README without the index', () {
      final tree = cleanTree()
        ..['README.md'] = '# Project\n'
        ..['docs/reports/0006-REPORT-unindexed.md'] =
            '---\nstatus: "partial"\n---\n# Unindexed\n';
      expect(run(tree, rules: ['layout']), [
        'layout README.md:0',
        'layout docs/reports/0006-REPORT-unindexed.md:0',
      ]);
    });

    test('F22 a record name outside the four kinds', () {
      final tree = cleanTree()
        ..['docs/decisions/0005-UX-BASELINE-x.md'] =
            '---\nstatus: "partial"\n---\n# Baseline\n'
        ..['docs/README.md'] =
            '${cleanTree()['docs/README.md']!}'
            '[b](decisions/0005-UX-BASELINE-x.md)\n';
      expect(run(tree, rules: ['layout']), [
        'layout docs/decisions/0005-UX-BASELINE-x.md:0',
      ]);
    });
  });

  group('this repository', () {
    final root = Directory.current;

    void expectClean(List<String> rules) {
      final findings = check(root, rules: rules);
      expect(
        findings,
        isEmpty,
        reason:
            'Documentation problems (`dart run tool/records.dart check`):\n'
            '${findings.join('\n')}',
      );
    }

    test('links, anchors and docs/ path mentions all resolve', () {
      expectClean(const ['links', 'anchors', 'paths']);
    });

    test('record numbering and frontmatter', () {
      expectClean(const ['numbering', 'frontmatter']);
    });

    test('the documentation tree has the standard layout, fully indexed', () {
      expectClean(const ['layout']);
    });

    test('the checker sees the records it claims to check', () {
      // A listing that silently came back empty would make every rule above
      // pass. Pin a floor rather than a count, so new records never break it.
      final records = recordsIn(checkedFiles(root));
      expect(records.length, greaterThan(100));
      expect(
        records.map((r) => r.path),
        contains(
          endsWith(
            '0054-MADR-docs-link-checker-and-standard-layout-migration.md',
          ),
        ),
      );
    });
  });
}
