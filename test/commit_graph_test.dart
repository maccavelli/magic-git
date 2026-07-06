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
  });
}
