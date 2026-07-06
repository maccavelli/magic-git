import 'dart:collection';
import 'dart:math';
import 'git_service.dart';

/// The kind of segment drawn within a single graph row.
enum GraphEdgeKind {
  /// A lane passing straight through this row (not involving the node).
  pass,

  /// A lane arriving from above that terminates at this row's node.
  toNode,

  /// A lane leaving this row's node toward a parent below.
  fromNode,
}

/// One line segment in a row, expressed in lane columns. [fromColumn] is the
/// lane at the top edge of the row, [toColumn] the lane at the bottom edge.
class GraphEdge {
  final int fromColumn;
  final int toColumn;
  final GraphEdgeKind kind;

  /// Lane index used to pick a stable color for the line.
  final int colorLane;

  const GraphEdge({
    required this.fromColumn,
    required this.toColumn,
    required this.kind,
    required this.colorLane,
  });
}

/// A laid-out commit row: the commit, the lane its node sits in, and the line
/// segments to draw around it.
class GraphRow {
  final GitCommit commit;
  final int column;
  final List<GraphEdge> edges;

  const GraphRow({
    required this.commit,
    required this.column,
    required this.edges,
  });
}

/// A fully laid-out commit graph.
class CommitGraph {
  final List<GraphRow> rows;
  final int laneCount;

  const CommitGraph({required this.rows, required this.laneCount});

  static const CommitGraph empty = CommitGraph(rows: [], laneCount: 0);

  /// Lays out commits (newest-first, as `git log` emits them) into lanes.
  ///
  /// Standard active-lane algorithm: each lane "expects" the hash of the next
  /// commit that should appear in it (a child's parent). A commit lands in the
  /// leftmost lane expecting it (or a new lane if it is a branch tip); its first
  /// parent inherits that lane, additional parents (merges) branch into new or
  /// existing lanes, and lanes that expected the commit collapse into its node.
  static CommitGraph build(List<GitCommit> commits) {
    final lanes = <String?>[]; // lanes[i] = hash the lane is waiting for
    final rows = <GraphRow>[];
    var laneCount = 0;

    // hash -> ascending-sorted lane indices currently expecting it (usually
    // one, but a commit with more than one child means more than one lane can
    // wait for the same hash at once) and the set of currently-null lane
    // indices — both maintained in lockstep with `lanes` below so a commit's
    // matching lanes, a parent's existing lane, and the next free lane are
    // all found without an O(laneCount) scan, unlike a full rescan of `lanes`
    // for every commit and every parent.
    final waiting = <String, List<int>>{};
    final freeLanes = SplayTreeSet<int>();

    void setLane(int i, String? hash) {
      final old = lanes[i];
      if (old != null) {
        final list = waiting[old];
        if (list != null) {
          list.remove(i);
          if (list.isEmpty) waiting.remove(old);
        }
      }
      lanes[i] = hash;
      if (hash == null) {
        freeLanes.add(i);
      } else {
        freeLanes.remove(i);
        final list = waiting.putIfAbsent(hash, () => []);
        var idx = 0;
        while (idx < list.length && list[idx] < i) {
          idx++;
        }
        list.insert(idx, i);
      }
    }

    int firstFree() {
      if (freeLanes.isNotEmpty) return freeLanes.first;
      lanes.add(null);
      freeLanes.add(lanes.length - 1);
      return lanes.length - 1;
    }

    for (final commit in commits) {
      final matching = List<int>.of(waiting[commit.hash] ?? const []);

      final nodeColumn = matching.isEmpty ? firstFree() : matching.first;

      // Snapshot the lanes as they enter this row (the top edge).
      final top = List<String?>.of(lanes);

      // Lanes that expected this commit collapse into the node.
      for (final i in matching) {
        setLane(i, null);
      }

      // Route parents. A parent already expected by an active lane reuses that
      // lane (so the commit merges into it immediately); otherwise the first
      // parent inherits the node's lane and extra parents branch into fresh
      // lanes. A node lane left unclaimed by any parent simply ends.
      final parentLanes = <int>[];
      if (commit.parents.isEmpty) {
        setLane(nodeColumn, null); // root commit — lane ends here
      } else {
        for (var p = 0; p < commit.parents.length; p++) {
          final parentHash = commit.parents[p];
          final existing = waiting[parentHash];
          var lane = (existing != null && existing.isNotEmpty)
              ? existing.first
              : -1;
          if (lane < 0) {
            lane = p == 0 ? nodeColumn : firstFree();
            setLane(lane, parentHash);
          }
          parentLanes.add(lane);
        }
      }

      // Build the row's line segments.
      final edges = <GraphEdge>[];
      for (var i = 0; i < top.length; i++) {
        final expected = top[i];
        if (expected == null) continue;
        if (expected == commit.hash) {
          edges.add(
            GraphEdge(
              fromColumn: i,
              toColumn: nodeColumn,
              kind: GraphEdgeKind.toNode,
              colorLane: i,
            ),
          );
        } else {
          edges.add(
            GraphEdge(
              fromColumn: i,
              toColumn: i,
              kind: GraphEdgeKind.pass,
              colorLane: i,
            ),
          );
        }
      }
      for (final lane in parentLanes) {
        edges.add(
          GraphEdge(
            fromColumn: nodeColumn,
            toColumn: lane,
            kind: GraphEdgeKind.fromNode,
            colorLane: lane,
          ),
        );
      }

      laneCount = max(laneCount, max(top.length, lanes.length));
      rows.add(GraphRow(commit: commit, column: nodeColumn, edges: edges));
    }

    return CommitGraph(rows: rows, laneCount: laneCount);
  }
}
