import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/git/commit_graph.dart';
import 'package:remote_magic_git/core/git/git_service.dart';

GitCommit c(String hash, List<String> parents) => GitCommit(
  hash: hash,
  shortHash: hash,
  authorName: 'a',
  authorEmail: 'a@b',
  date: '2020-01-01T00:00:00Z',
  parents: parents,
  subject: hash,
);

/// Structural equality for two laid-out graphs — [GraphRow]/[GraphEdge] have no
/// `==`, so compare the fields that determine what gets painted.
void expectSameGraph(CommitGraph a, CommitGraph b) {
  expect(a.laneCount, b.laneCount);
  expect(a.rows.length, b.rows.length);
  for (var i = 0; i < a.rows.length; i++) {
    final ra = a.rows[i];
    final rb = b.rows[i];
    expect(ra.commit.hash, rb.commit.hash, reason: 'row $i hash');
    expect(ra.column, rb.column, reason: 'row $i column');
    expect(ra.edges.length, rb.edges.length, reason: 'row $i edge count');
    for (var j = 0; j < ra.edges.length; j++) {
      final ea = ra.edges[j];
      final eb = rb.edges[j];
      expect(
        [ea.fromColumn, ea.toColumn, ea.kind.index, ea.colorLane],
        [eb.fromColumn, eb.toColumn, eb.kind.index, eb.colorLane],
        reason: 'row $i edge $j',
      );
    }
  }
}

void main() {
  group('CommitGraph.build', () {
    test('empty input yields an empty graph', () {
      final g = CommitGraph.build([]);
      expect(g.rows, isEmpty);
      expect(g.laneCount, 0);
    });

    test('linear history stays in a single lane', () {
      // C -> B -> A (newest first)
      final g = CommitGraph.build([
        c('C', ['B']),
        c('B', ['A']),
        c('A', []),
      ]);
      expect(g.laneCount, 1);
      expect(g.rows.map((r) => r.column), everyElement(0));
      // The root commit emits no outgoing (fromNode) edge.
      final rootEdges = g.rows.last.edges;
      expect(rootEdges.any((e) => e.kind == GraphEdgeKind.fromNode), isFalse);
    });

    test('a fork-and-merge occupies a second lane then collapses', () {
      // M merges P1 and P2, both of which descend from B.
      //   M -> [P1, P2], P1 -> [B], P2 -> [B], B -> []
      final g = CommitGraph.build([
        c('M', ['P1', 'P2']),
        c('P1', ['B']),
        c('P2', ['B']),
        c('B', []),
      ]);

      expect(g.laneCount, 2);

      final m = g.rows[0];
      final p1 = g.rows[1];
      final p2 = g.rows[2];
      final b = g.rows[3];

      expect(m.column, 0);
      expect(p1.column, 0);
      expect(p2.column, 1); // the second parent took a new lane
      expect(b.column, 0);

      // M branches into two lanes (two fromNode edges to distinct columns).
      final mBranches = m.edges
          .where((e) => e.kind == GraphEdgeKind.fromNode)
          .toList();
      expect(mBranches.map((e) => e.toColumn).toSet(), {0, 1});

      // P2 merges back into lane 0 (its parent B already lives in lane 0).
      final p2Merge = p2.edges.firstWhere(
        (e) => e.kind == GraphEdgeKind.fromNode,
      );
      expect(p2Merge.toColumn, 0);
    });

    test('a lane passes through a row it is not involved in', () {
      // Feature branch F sits in its own lane across an unrelated main commit.
      //   main2 -> [main1], F -> [main1], main1 -> []
      // log order: main2, F, main1
      final g = CommitGraph.build([
        c('main2', ['main1']),
        c('F', ['main1']),
        c('main1', []),
      ]);
      // At the F row, main2's lane (waiting for main1) must pass through.
      final fRow = g.rows[1];
      expect(fRow.edges.any((e) => e.kind == GraphEdgeKind.pass), isTrue);
    });

    // History view lays out large histories on a background isolate
    // (`Isolate.run(() => CommitGraph.build(commits))`). Serializing
    // GitCommit across the isolate boundary and running the pure algorithm
    // there must produce byte-identical layout to the synchronous path.
    test('off-isolate build matches the synchronous build', () async {
      // A fixture with forks, merges, a long-lived side lane and enough volume
      // to be a realistic large-history layout.
      final commits = <GitCommit>[
        c('M', ['T', 'F3']), // merge feature back into trunk
        c('T', ['T2']),
        c('F3', ['F2']),
        c('T2', ['T3']),
        c('F2', ['F1']),
        c('T3', ['B']),
        c('F1', ['B']), // feature forked from B
      ];
      // Extend the trunk into a long linear tail so the graph is sizeable.
      var prev = 'B';
      commits.add(c('B', ['L0']));
      for (var i = 0; i < 500; i++) {
        final next = i == 499 ? <String>[] : ['L${i + 1}'];
        commits.add(c('L$i', next));
        prev = 'L$i';
      }
      expect(prev, 'L499');

      final sync = CommitGraph.build(commits);
      final iso = await Isolate.run(() => CommitGraph.build(commits));
      expectSameGraph(iso, sync);
    });

    test('headSha parameter pins the primary branch chain to Lane 0', () {
      // Feature branch tip F appears first in log, but headSha specifies main branch tip M.
      // F -> [B], M -> [B], B -> []
      final commits = [
        c('F', ['B']),
        c('M', ['B']),
        c('B', []),
      ];

      final g = CommitGraph.build(commits, headSha: 'M');
      final fRow = g.rows.firstWhere((r) => r.commit.hash == 'F');
      final mRow = g.rows.firstWhere((r) => r.commit.hash == 'M');
      final bRow = g.rows.firstWhere((r) => r.commit.hash == 'B');

      expect(
        mRow.column,
        0,
        reason: 'M is on primary chain (HEAD), stays in Lane 0',
      );
      expect(
        bRow.column,
        0,
        reason: 'B is on primary chain (HEAD), stays in Lane 0',
      );
      expect(fRow.column, 1, reason: 'F is on side branch, assigned to Lane 1');
    });

    test(
      'merge commit marks non-primary parent edges with isMergeEdge = true',
      () {
        // M merges P1 (mainline) and P2 (side branch).
        final g = CommitGraph.build([
          c('M', ['P1', 'P2']),
          c('P1', ['B']),
          c('P2', ['B']),
          c('B', []),
        ]);

        final m = g.rows[0];
        final mergeEdges = m.edges
            .where((e) => e.kind == GraphEdgeKind.fromNode)
            .toList();
        expect(mergeEdges.length, 2);

        final mainEdge = mergeEdges.firstWhere((e) => e.toColumn == 0);
        final sideEdge = mergeEdges.firstWhere((e) => e.toColumn == 1);

        expect(
          mainEdge.isMergeEdge,
          isFalse,
          reason: 'First parent P1 is mainline edge',
        );
        expect(
          sideEdge.isMergeEdge,
          isTrue,
          reason: 'Second parent P2 is merge edge',
        );
      },
    );

    test('deduplicates duplicate parent hashes safely', () {
      final g = CommitGraph.build([
        c('M', ['P1', 'P1']), // Duplicate parent
        c('P1', []),
      ]);

      expect(g.rows.length, 2);
      final m = g.rows[0];
      final fromEdges = m.edges
          .where((e) => e.kind == GraphEdgeKind.fromNode)
          .toList();
      expect(
        fromEdges.length,
        1,
        reason: 'Duplicate parent P1 is deduplicated',
      );
    });

    test('filtered list with missing parents does not leak lanes (F4)', () {
      // A filtered log with gaps: commits C, B, A are present but their parents
      // (X, Y) are NOT in the list. Before the fix, each missing parent would
      // reserve a lane that never collapses, causing O(N) lane growth.
      final commits = [
        c('C', ['X']), // X not in list
        c('B', ['Y']), // Y not in list
        c('A', []),
      ];
      final g = CommitGraph.build(commits);

      // Without the fix, laneCount would grow with each missing parent.
      // With the fix, missing parents don't reserve lanes, so we stay compact.
      expect(
        g.laneCount,
        lessThanOrEqualTo(2),
        reason: 'Missing parents must not leak lanes',
      );

      // Each commit with a missing parent should still have a fromNode edge
      // (to show the user the commit has a parent), routed to the node's own
      // column rather than a new lane.
      final cRow = g.rows[0];
      final fromEdges = cRow.edges
          .where((e) => e.kind == GraphEdgeKind.fromNode)
          .toList();
      expect(fromEdges.length, 1, reason: 'C still shows it has a parent');
      expect(
        fromEdges.first.toColumn,
        cRow.column,
        reason: 'Missing parent routes to own column, not a new lane',
      );
    });

    test('large filtered log stays compact, not O(N) lanes', () {
      // Simulate a real filtered log: 100 commits, each with a parent NOT in
      // the list (as happens with `git log --grep=...`).
      final commits = <GitCommit>[];
      for (var i = 0; i < 100; i++) {
        commits.add(c('c$i', ['missing_$i'])); // parent not in list
      }
      final g = CommitGraph.build(commits);

      // Before the fix, this would produce ~100 lanes.
      // After the fix, it should stay very compact (1-2 lanes).
      expect(
        g.laneCount,
        lessThanOrEqualTo(2),
        reason:
            'Filtered log with 100 disconnected commits must not '
            'explode to 100 lanes',
      );
    });

    test('filtered log with some parents present handles mixed case', () {
      // E -> D -> C -> [missing], B -> [missing], A -> []
      // D and C are contiguous, but C's parent is missing.
      final commits = [
        c('E', ['D']),
        c('D', ['C']),
        c('C', ['missing']),
        c('B', ['also_missing']),
        c('A', []),
      ];
      final g = CommitGraph.build(commits);

      // E-D-C form a chain in lane 0. B and A are disconnected.
      // Missing parents should not leak lanes.
      expect(
        g.laneCount,
        lessThanOrEqualTo(3),
        reason: 'Mixed present/missing parents stay compact',
      );

      // E-D chain should be in the same lane
      final eRow = g.rows[0];
      final dRow = g.rows[1];
      final cRow = g.rows[2];
      expect(eRow.column, dRow.column, reason: 'E and D are in the same lane');
      expect(dRow.column, cRow.column, reason: 'D and C are in the same lane');
    });
  });
}
