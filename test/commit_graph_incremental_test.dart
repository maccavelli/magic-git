// MADR 0039 A2, and its amendment 0039.1.
//
// Paging history used to re-lay-out the whole loaded list: each page produced a
// new list instance, so ten pages of 2,000 meant ten builds of a growing prefix
// — quadratic in total work, and in bytes copied through the isolate, for a
// result whose first N rows were bit-identical every time.
//
// The record's first claim about this was WRONG, and this file is the guard
// against the mistake it invited. It said the only state carried between rows is
// `lanes`, `waiting` and `freeLanes`. `allHashes` is carried too: it decides
// whether a parent is inside the loaded history (reserve a lane) or beyond its
// boundary (draw a stub and reserve nothing), and that answer CHANGES when the
// next page arrives. A naive resume freezes those boundary rows as stubs and
// diverges from the from-scratch layout — silently, and only on the rows a user
// is looking at when they page.
//
// So the contract is identity, not approximation: an appended layout must be
// row-for-row and edge-for-edge what a from-scratch build of the concatenated
// list produces. That is asserted here over hand-built fixtures whose shapes are
// the ones that go wrong, and over 200 randomised DAGs.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/commit_graph.dart';
import 'package:remote_magic_git/core/git/git_service.dart';

GitCommit _c(String hash, List<String> parents) => GitCommit(
  hash: hash,
  shortHash: hash,
  authorName: 'a',
  authorEmail: 'a@example.com',
  date: '2026-01-01T00:00:00Z',
  parents: parents,
  subject: hash,
);

/// Every field of a laid-out graph that a painter can see.
String _fingerprint(CommitGraph g) {
  final b = StringBuffer()..writeln('lanes=${g.laneCount}');
  for (final row in g.rows) {
    b.write('${row.commit.hash}@${row.column}');
    for (final e in row.edges) {
      b.write(
        ' [${e.fromColumn}->${e.toColumn} ${e.kind.name} '
        'c${e.colorLane}${e.isMergeEdge ? " merge" : ""}]',
      );
    }
    b.writeln();
  }
  return b.toString();
}

/// Asserts that appending [page2] to [page1] is indistinguishable from building
/// the whole thing at once.
void _expectIdentical(
  List<GitCommit> page1,
  List<GitCommit> page2, {
  String? headSha,
  String? reason,
}) {
  final first = CommitGraph.buildResumable(page1, headSha: headSha);
  final appended = CommitGraph.append(
    first.state,
    first.graph.rows,
    page2,
    headSha: headSha,
  );
  final whole = CommitGraph.build([...page1, ...page2], headSha: headSha);

  expect(_fingerprint(appended.graph), _fingerprint(whole), reason: reason);
}

void main() {
  group('append is identical to a from-scratch build', () {
    test('a plain linear history split across two pages', () {
      final all = [
        for (var i = 0; i < 10; i++) _c('c$i', i == 9 ? [] : ['c${i + 1}']),
      ];
      _expectIdentical(all.sublist(0, 5), all.sublist(5), headSha: 'c0');
    });

    test('a merge whose second parent is on the next page', () {
      // The boundary case the amendment is about: when only page 1 is loaded,
      // `side` is outside the history and the merge draws a stub. Once page 2
      // lands it is inside, and that row must be laid out again.
      final page1 = [
        _c('merge', ['main1', 'side']),
        _c('main1', ['main2']),
      ];
      final page2 = [
        _c('side', ['main2']),
        _c('main2', []),
      ];
      _expectIdentical(page1, page2, headSha: 'merge');
    });

    test('an octopus merge straddling the boundary', () {
      final page1 = [
        _c('octo', ['p1', 'p2', 'p3']),
        _c('p1', ['base']),
      ];
      final page2 = [
        _c('p2', ['base']),
        _c('p3', ['base']),
        _c('base', []),
      ];
      _expectIdentical(page1, page2, headSha: 'octo');
    });

    test('a long-lived side branch open across the boundary', () {
      final page1 = [
        _c('m0', ['m1']),
        _c('m1', ['m2']),
        _c('sideTip', ['sideMid']),
        _c('m2', ['m3']),
      ];
      final page2 = [
        _c('sideMid', ['sideBase']),
        _c('m3', ['sideBase']),
        _c('sideBase', []),
      ];
      _expectIdentical(page1, page2, headSha: 'm0');
    });

    test('a filtered log whose parents are never loaded', () {
      // Nothing on page 2 resolves the stubs, so the boundary rows must come out
      // exactly as they did — the append must not invent lanes for parents that
      // still are not there.
      final page1 = [
        _c('a', ['missingA']),
        _c('b', ['missingB']),
      ];
      final page2 = [
        _c('c', ['missingC']),
        _c('d', ['missingD']),
      ];
      _expectIdentical(page1, page2, headSha: 'a');
    });

    test('a page that supplies the spine itself', () {
      // The chain-extension case with teeth. HEAD is not in page 1 at all, so
      // the spine walk finds nothing and `primaryChain` is EMPTY — which sends
      // the side commit to lane 0, because there is no spine to reserve it for.
      // Page 2 brings HEAD in; the chain must continue from where the walk
      // stopped, or the side commit keeps a lane it is no longer entitled to.
      final page1 = [
        _c('side', ['base']),
      ];
      final page2 = [
        _c('head', ['base']),
        _c('base', []),
      ];
      _expectIdentical(page1, page2, headSha: 'head');
    });

    test('a page that resolves the spine walk', () {
      // The primary chain stops where a first parent is not loaded; the append
      // must continue it rather than leaving lane 0 unpinned for the new rows.
      final page1 = [
        _c('h0', ['h1']),
        _c('h1', ['h2']),
      ];
      final page2 = [
        _c('h2', ['h3']),
        _c('h3', []),
      ];
      _expectIdentical(page1, page2, headSha: 'h0');
    });

    test('an empty appended page changes nothing', () {
      final page1 = [
        _c('a', ['b']),
        _c('b', []),
      ];
      _expectIdentical(page1, const [], headSha: 'a');
    });

    test('three pages appended one after another', () {
      final all = [
        for (var i = 0; i < 12; i++) _c('c$i', i == 11 ? [] : ['c${i + 1}']),
      ];
      var acc = CommitGraph.buildResumable(all.sublist(0, 4), headSha: 'c0');
      acc = CommitGraph.append(
        acc.state,
        acc.graph.rows,
        all.sublist(4, 8),
        headSha: 'c0',
      );
      acc = CommitGraph.append(
        acc.state,
        acc.graph.rows,
        all.sublist(8),
        headSha: 'c0',
      );

      expect(
        _fingerprint(acc.graph),
        _fingerprint(CommitGraph.build(all, headSha: 'c0')),
        reason: 'resuming twice must not drift from resuming once',
      );
    });
  });

  test('200 randomised DAGs append identically', () {
    // Topological, newest-first, exactly as `git log --topo-order` emits: a
    // commit's parents are always later in the list. Merge rate and page split
    // vary, so boundaries land in every part of the shape.
    for (var seed = 0; seed < 200; seed++) {
      final rng = Random(seed);
      final n = 6 + rng.nextInt(25);
      final commits = <GitCommit>[];
      for (var i = 0; i < n; i++) {
        final remaining = n - i - 1;
        final parents = <String>[];
        if (remaining > 0) {
          parents.add('c${i + 1 + rng.nextInt(remaining)}');
          // A merge every so often, and sometimes an octopus.
          final extra = rng.nextInt(10);
          if (extra < 3 && remaining > 1) {
            parents.add('c${i + 1 + rng.nextInt(remaining)}');
          }
          if (extra == 0 && remaining > 2) {
            parents.add('c${i + 1 + rng.nextInt(remaining)}');
          }
        } else if (rng.nextBool()) {
          // A root whose parent was never loaded — the filtered-log case.
          parents.add('never-loaded-$seed');
        }
        commits.add(_c('c$i', parents));
      }

      final split = 1 + rng.nextInt(n - 1);
      final first = CommitGraph.buildResumable(
        commits.sublist(0, split),
        headSha: 'c0',
      );
      final appended = CommitGraph.append(
        first.state,
        first.graph.rows,
        commits.sublist(split),
        headSha: 'c0',
      );
      final whole = CommitGraph.build(commits, headSha: 'c0');

      expect(
        _fingerprint(appended.graph),
        _fingerprint(whole),
        reason: 'seed=$seed n=$n split=$split — rerun with that seed to debug',
      );
    }
  });

  test('the resume point is a real saving, not the whole list', () {
    // If `resumeFromRow` were always 0 the layout would be identical and every
    // test above would still pass, having proved nothing about the cost. On a
    // history whose parents are all loaded, nothing can change and the resume
    // point is the end of the list.
    final closed = [
      for (var i = 0; i < 20; i++) _c('c$i', i == 19 ? [] : ['c${i + 1}']),
    ];
    final built = CommitGraph.buildResumable(closed, headSha: 'c0');
    expect(
      built.state.resumeFromRow,
      closed.length,
      reason:
          'a fully-resolved history has no row that a later page can change',
    );

    // And on a page with an open boundary it is the first row that reaches past
    // it — not row 0.
    final open = [
      _c('a', ['b']),
      _c('b', ['c']),
      _c('c', ['beyond-the-page']),
    ];
    expect(
      CommitGraph.buildResumable(open, headSha: 'a').state.resumeFromRow,
      2,
    );
  });

  test('rows before the resume point are reused, not rebuilt', () {
    // The saving itself. Identity, not equality: a rebuilt prefix would compare
    // equal by the fingerprint above and prove nothing, so every test in this
    // file would still pass while the phase did no work at all.
    final page1 = [
      _c('a', ['b']),
      _c('b', ['c']),
      _c('c', ['beyond-the-page']),
    ];
    final page2 = [
      _c('beyond-the-page', ['z']),
      _c('z', []),
    ];

    final first = CommitGraph.buildResumable(page1, headSha: 'a');
    expect(first.state.resumeFromRow, 2, reason: 'row c reaches past the page');

    final appended = CommitGraph.append(
      first.state,
      first.graph.rows,
      page2,
      headSha: 'a',
    );

    for (var i = 0; i < first.state.resumeFromRow; i++) {
      expect(
        identical(appended.graph.rows[i], first.graph.rows[i]),
        isTrue,
        reason: 'row $i cannot have changed, so it must not be laid out again',
      );
    }
    expect(
      identical(appended.graph.rows[2], first.graph.rows[2]),
      isFalse,
      reason:
          'row 2 drew a stub for a parent that has now arrived — it MUST '
          'be laid out again, which is the whole point of amendment 0039.1',
    );
  });

  test('HistoryView pages through append, not a fresh build', () {
    // The identity contract makes "did it resume?" invisible from outside — a
    // resumed layout and a rebuilt one are the same graph, deliberately. So the
    // wiring is pinned the only way that can fail: by membership. Without this,
    // `CommitGraph.append` could be perfect and entirely unreachable.
    final source = const Utf8Decoder(
      allowMalformed: true,
    ).convert(File('lib/features/history/history_view.dart').readAsBytesSync());

    expect(
      source,
      contains('CommitGraph.append('),
      reason: 'the paging path must resume the previous layout',
    );
    // The EXACT guard, not a substring of it. A weaker check — merely that the
    // predicate is mentioned — is satisfied by a dead `false &&` in front of it,
    // which is precisely how this wiring would stop running without any test
    // noticing. Same reasoning as the LRU clear-list guard.
    expect(
      source,
      contains(
        'if (state != null &&\n'
        '        previous != null &&\n'
        '        headSha == _lastHeadSha &&\n'
        '        _isPrefixExtensionOfLast(commits)) {',
      ),
      reason:
          'the resume path must be reachable and guarded by exactly the '
          'prefix-extension test — nothing more, nothing less',
    );
    expect(
      source,
      contains('_graphState = null;'),
      reason: 'a repo switch must drop lane state describing another history',
    );
  });
}
