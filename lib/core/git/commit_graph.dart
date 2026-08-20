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

  /// Whether this edge represents a non-mainline merge parent line (parent 2+).
  final bool isMergeEdge;

  const GraphEdge({
    required this.fromColumn,
    required this.toColumn,
    required this.kind,
    required this.colorLane,
    this.isMergeEdge = false,
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
  /// Pins the primary branch (HEAD or primary ancestor chain) to Lane 0 so the
  /// main timeline forms a straight, stable vertical spine on the left. Side
  /// branches branch out into higher lanes and curve back in when merged.
  static CommitGraph build(
    List<GitCommit> commits, {
    String? headSha,
    String? mainBranchSha,
  }) {
    if (commits.isEmpty) return empty;

    // Build lookup for commits in this list.
    final commitByHash = <String, GitCommit>{};
    final allHashes = <String>{};
    for (final c in commits) {
      commitByHash[c.hash] = c;
      allHashes.add(c.hash);
    }

    // Determine the primary branch spine (following first parents).
    final primaryChain = <String>{};
    String? currentSha = headSha ?? mainBranchSha ?? commits.first.hash;
    while (currentSha != null && commitByHash.containsKey(currentSha)) {
      primaryChain.add(currentSha);
      final c = commitByHash[currentSha]!;
      currentSha = c.parents.isNotEmpty ? c.parents.first : null;
    }

    final lanes = <String?>[]; // lanes[i] = hash the lane is waiting for
    final rows = <GraphRow>[];
    var laneCount = 0;

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

    int firstFreeNonZero() {
      for (final l in freeLanes) {
        if (l > 0) return l;
      }
      if (lanes.isEmpty) {
        lanes.add(null); // lane 0
        freeLanes.add(0);
      }
      final i = lanes.length;
      lanes.add(null);
      freeLanes.add(i);
      return i;
    }

    for (final commit in commits) {
      final matching = List<int>.of(waiting[commit.hash] ?? const []);
      final isPrimary = primaryChain.contains(commit.hash);

      int nodeColumn;
      if (matching.contains(0)) {
        nodeColumn = 0;
      } else if (matching.isNotEmpty) {
        nodeColumn = matching.first;
      } else if (isPrimary &&
          (freeLanes.contains(0) || lanes.isEmpty || lanes[0] == null)) {
        nodeColumn = 0;
        if (lanes.isEmpty) {
          lanes.add(null);
          freeLanes.add(0);
        }
      } else if (!isPrimary &&
          primaryChain.isNotEmpty &&
          (lanes.isEmpty || lanes[0] == null || freeLanes.contains(0))) {
        // Side branch (or filtered-log orphan): keep lane 0 for the primary
        // spine. firstFreeNonZero reuses freed non-zero lanes so a filtered
        // log with missing parents stays compact (F4).
        nodeColumn = firstFreeNonZero();
      } else {
        nodeColumn = firstFree();
      }

      // Snapshot the lanes as they enter this row (the top edge).
      final top = List<String?>.of(lanes);

      // Lanes that expected this commit collapse into the node.
      for (final i in matching) {
        setLane(i, null);
      }

      // Deduplicate parent hashes.
      final parents = <String>[];
      for (final p in commit.parents) {
        if (!parents.contains(p)) parents.add(p);
      }

      // Route parents.
      final parentLanes = <(int, bool)>[]; // (laneIndex, isMergeEdge)
      if (parents.isEmpty) {
        setLane(nodeColumn, null); // root commit — lane ends here
      } else {
        for (var p = 0; p < parents.length; p++) {
          final parentHash = parents[p];
          final isMerge = p > 0;

          if (!allHashes.contains(parentHash)) {
            // Parent is outside this list (filtered log / truncated page).
            // Draw a stub edge to the node's own column without reserving a
            // waiting lane — that is what previously leaked O(N) lanes.
            parentLanes.add((nodeColumn, isMerge));
            if (p == 0) {
              setLane(nodeColumn, null);
            }
            continue;
          }

          final existing = waiting[parentHash];
          var lane = -1;

          if (p == 0 && (isPrimary || nodeColumn == 0)) {
            if (existing != null && existing.contains(0)) {
              lane = 0;
            } else if (lanes.isEmpty ||
                lanes[0] == null ||
                freeLanes.contains(0) ||
                nodeColumn == 0) {
              lane = 0;
              if (lanes.isEmpty) lanes.add(null);
              setLane(0, parentHash);
            }
          }

          if (lane < 0) {
            lane = (existing != null && existing.isNotEmpty)
                ? existing.first
                : -1;
            if (lane < 0) {
              lane = p == 0 ? nodeColumn : firstFree();
              setLane(lane, parentHash);
            }
          }
          parentLanes.add((lane, isMerge));
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
          // If expected is not in the remaining commits set and no lane matches,
          // it's an un-fetched parent beyond the loaded boundary.
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
      for (final (lane, isMerge) in parentLanes) {
        edges.add(
          GraphEdge(
            fromColumn: nodeColumn,
            toColumn: lane,
            kind: GraphEdgeKind.fromNode,
            colorLane: lane,
            isMergeEdge: isMerge,
          ),
        );
      }

      laneCount = max(laneCount, max(top.length, lanes.length));
      rows.add(GraphRow(commit: commit, column: nodeColumn, edges: edges));
    }

    return CommitGraph(rows: rows, laneCount: laneCount);
  }
}
