// MADR 0052: every status bar that names the active repository takes the name
// from `repositoryDisplayNameProvider`, so the tab title, window title,
// Repository row and status bar cannot drift apart. The Worktrees pane's
// `Worktree:` site names a different checkout and is the one exception.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// One `repositoryName:` named argument: the file it is in and its text, from
/// the label to the line before the next named argument.
typedef _Site = ({String file, String text});

final _nextNamedArgument = RegExp(r'^\s*\w+:');

List<_Site> _repositoryNameSites() {
  final sites = <_Site>[];
  final files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'));
  for (final file in files) {
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final at = lines[i].indexOf('repositoryName:');
      if (at < 0) continue;
      final text = StringBuffer(lines[i].substring(at));
      for (var j = i + 1; j < lines.length; j++) {
        if (_nextNamedArgument.hasMatch(lines[j])) break;
        text.writeln(lines[j]);
      }
      sites.add((file: file.path, text: text.toString()));
    }
  }
  return sites;
}

void main() {
  test('every repository status-bar name comes from the shared provider', () {
    final sites = _repositoryNameSites();
    expect(
      sites,
      hasLength(7),
      reason:
          'expected the six pane status bars plus the Worktree site; a new '
          'site is a naming decision to make, not to absorb:\n'
          '${sites.map((s) => s.file).join('\n')}',
    );

    final worktree = sites.where((s) => s.text.contains("'Worktree: "));
    expect(worktree, hasLength(1));
    expect(worktree.single.file, endsWith('worktrees_view.dart'));

    for (final site in sites.where((s) => !s.text.contains("'Worktree: "))) {
      expect(
        site.text,
        contains('repositoryDisplayNameProvider('),
        reason: '${site.file} names the repository itself:\n${site.text}',
      );
    }
    for (final site in sites) {
      expect(
        site.text,
        isNot(contains(".split('/')")),
        reason: '${site.file} splits the path by hand:\n${site.text}',
      );
    }
  });
}
