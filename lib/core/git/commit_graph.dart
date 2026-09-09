import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart' show immutable;

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

/// Everything a later page needs to resume the layout instead of redoing it.
///
/// Opaque by intent: only [CommitGraph.append] reads it. It carries the lane
/// bookkeeping **as it was entering [resumeFromRow]**, not as it was at the end
/// of the walk, and that is the whole subtlety of resuming this algorithm.
///
/// [CommitGraph.build] decides between a real lane and a stub edge by asking
/// whether a parent is present in the loaded history at all. That answer is not
/// append-invariant: a parent that is beyond the boundary while page 1 is loaded
/// is *inside* the history once page 2 arrives, so every row that drew such a
/// stub has to be laid out again. [resumeFromRow] is the first of them, and
/// rows before it are provably unaffected — nothing they drew depends on a
/// commit that had not been seen yet.
@immutable
class GraphLayoutState {
  const GraphLayoutState({
    required this.lanes,
    required this.waiting,
    required this.freeLanes,
    required this.primaryChain,
    required this.chainNext,
    required this.resumeFromRow,
    required this.laneCountBefore,
  });

  /// `lanes[i]` is the hash lane *i* is waiting for, entering [resumeFromRow].
  final List<String?> lanes;

  /// hash → the lanes waiting for it, ascending.
  final Map<String, List<int>> waiting;

  /// Lane indices currently unoccupied.
  final List<int> freeLanes;

  /// The first-parent spine found so far.
  final Set<String> primaryChain;

  /// Where the spine walk stopped — a hash that was not in the loaded history,
  /// or null if the walk reached a root. An appended page can continue from it.
  final String? chainNext;

  /// First row whose layout can still change as more history loads.
  final int resumeFromRow;

  /// The running lane-count maximum over the rows before [resumeFromRow].
  final int laneCountBefore;
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
  }) => buildResumable(
    commits,
    headSha: headSha,
    mainBranchSha: mainBranchSha,
  ).graph;

  /// [build], plus the state an [append] needs.
  static ({CommitGraph graph, GraphLayoutState state}) buildResumable(
    List<GitCommit> commits, {
    String? headSha,
    String? mainBranchSha,
  }) {
    final commitByHash = <String, GitCommit>{};
    final allHashes = <String>{};
    for (final c in commits) {
      commitByHash[c.hash] = c;
      allHashes.add(c.hash);
    }

    // Determine the primary branch spine (following first parents).
    final primaryChain = <String>{};
    String? currentSha = commits.isEmpty
        ? (headSha ?? mainBranchSha)
        : (headSha ?? mainBranchSha ?? commits.first.hash);
    while (currentSha != null && commitByHash.containsKey(currentSha)) {
      primaryChain.add(currentSha);
      final c = commitByHash[currentSha]!;
      currentSha = c.parents.isNotEmpty ? c.parents.first : null;
    }

    return _layout(
      commits: commits,
      commitByHash: commitByHash,
      allHashes: allHashes,
      primaryChain: primaryChain,
      chainNext: currentSha,
      startRow: 0,
      resume: null,
      previousRows: const [],
    );
  }

  /// Lays out [newCommits] on top of an earlier page, redoing only the rows
  /// whose result can have changed.
  ///
  /// [previousRows] is the earlier [CommitGraph.rows] and [state] its
  /// [GraphLayoutState]. Rows before `state.resumeFromRow` are reused verbatim;
  /// the rest are laid out again over the combined history, because a parent
  /// that was beyond the boundary may now be inside it.
  ///
  /// The result is required to be identical to a from-scratch [build] of the
  /// concatenated list — `commit_graph_incremental_test.dart` asserts exactly
  /// that, over fixtures and randomised DAGs, and it is a precondition of this
  /// method rather than a nicety (MADR 0039 A2, amendment 0039.1).
  static ({CommitGraph graph, GraphLayoutState state}) append(
    GraphLayoutState state,
    List<GraphRow> previousRows,
    List<GitCommit> newCommits, {
    String? headSha,
    String? mainBranchSha,
  }) {
    final commits = [for (final r in previousRows) r.commit, ...newCommits];
    final commitByHash = <String, GitCommit>{};
    final allHashes = <String>{};
    for (final c in commits) {
      commitByHash[c.hash] = c;
      allHashes.add(c.hash);
    }

    // Continue the spine from where it stopped rather than re-walking it.
    final primaryChain = <String>{...state.primaryChain};
    String? currentSha = state.chainNext;
    while (currentSha != null && commitByHash.containsKey(currentSha)) {
      primaryChain.add(currentSha);
      final c = commitByHash[currentSha]!;
      currentSha = c.parents.isNotEmpty ? c.parents.first : null;
    }

    return _layout(
      commits: commits,
      commitByHash: commitByHash,
      allHashes: allHashes,
      primaryChain: primaryChain,
      chainNext: currentSha,
      startRow: state.resumeFromRow,
      resume: state,
      previousRows: previousRows,
    );
  }

  /// The lane walk itself, shared by [buildResumable] and [append].
  ///
  /// Lays out `commits[startRow..]`, prepending `previousRows[0..startRow)`
  /// unchanged, and captures the state entering the first row that draws a stub
  /// for a parent outside the loaded history.
  static ({CommitGraph graph, GraphLayoutState state}) _layout({
    required List<GitCommit> commits,
    required Map<String, GitCommit> commitByHash,
    required Set<String> allHashes,
    required Set<String> primaryChain,
    required String? chainNext,
    required int startRow,
    required GraphLayoutState? resume,
    required List<GraphRow> previousRows,
  }) {
    if (commits.isEmpty) {
      return (
        graph: empty,
        state: GraphLayoutState(
          lanes: const [],
          waiting: const {},
          freeLanes: const [],
          primaryChain: primaryChain,
          chainNext: chainNext,
          resumeFromRow: 0,
          laneCountBefore: 0,
        ),
      );
    }

    // The first row whose parents reach outside the loaded history. Everything
    // from here on can change as more pages arrive, so it is where the next
    // append resumes — and, on this pass, the row whose entering state is
    // captured. A cheap pre-scan: no layout is needed to answer it.
    var nextResumeFrom = commits.length;
    for (var i = startRow; i < commits.length; i++) {
      if (commits[i].parents.any((p) => !allHashes.contains(p))) {
        nextResumeFrom = i;
        break;
      }
    }

    final lanes = <String?>[...?resume?.lanes];
    final rows = <GraphRow>[...previousRows.take(startRow)];
    var laneCount = resume?.laneCountBefore ?? 0;

    final waiting = <String, List<int>>{
      for (final e in (resume?.waiting ?? const <String, List<int>>{}).entries)
        e.key: [...e.value],
    };
    final freeLanes = SplayTreeSet<int>()
      ..addAll(resume?.freeLanes ?? const []);

    List<String?>? snapLanes;
    Map<String, List<int>>? snapWaiting;
    List<int>? snapFree;
    var snapLaneCount = 0;

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

    for (var row = startRow; row < commits.length; row++) {
      final commit = commits[row];
      if (row == nextResumeFrom) {
        // The state entering this row is what the next page resumes from.
        snapLanes = List<String?>.of(lanes);
        snapWaiting = {
          for (final e in waiting.entries) e.key: [...e.value],
        };
        snapFree = freeLanes.toList();
        snapLaneCount = laneCount;
      }
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

    return (
      graph: CommitGraph(rows: rows, laneCount: laneCount),
      state: GraphLayoutState(
        lanes: snapLanes ?? List<String?>.of(lanes),
        waiting:
            snapWaiting ??
            {
              for (final e in waiting.entries) e.key: [...e.value],
            },
        freeLanes: snapFree ?? freeLanes.toList(),
        primaryChain: primaryChain,
        chainNext: chainNext,
        resumeFromRow: nextResumeFrom,
        laneCountBefore: snapLanes == null ? laneCount : snapLaneCount,
      ),
    );
  }
}
