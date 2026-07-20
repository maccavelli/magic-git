import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:macos_window_utils/widgets/transparent_macos_sidebar.dart';
import 'package:macos_window_utils/widgets/visual_effect_subview_container/visual_effect_subview_container_resize_event_relay.dart';
import '../../core/git/repo_tree.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/pane_layout.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/git_porcelain_parser.dart';
import '../../core/utils/file_actions.dart';
import '../common/actions.dart';
import '../common/context_menu.dart';
import '../common/escape_dismissible.dart';
import '../common/status_style.dart';
import '../common/tappable.dart';
import '../common/tool_icon_button.dart';
import '../history/file_history_sheet.dart';
import '../viewer/viewer_providers.dart';
import '../viewer/remote_edit_service.dart';
import 'blame_sheet.dart';

/// Called when a file is chosen in the tree so the host panel can show its diff.
/// [staged]/[untracked] mirror the `_selected` tuple used by the status list.
typedef OpenFileCallback =
    void Function(String path, {required bool staged, required bool untracked});

/// The user-resizable file-tree pane docked on the right of the Repository
/// panel. Renders [repoStructureProvider] (the stable tree shape) recolored by
/// [repoStatusOverlayProvider]: directories are green when they hold
/// uncommitted/unadded work and blue when clean (white names), git-ignored
/// entries muted, with wholly-ignored directories expanded lazily. Structure and
/// status are separate so a save recolors atomically without rebuilding the
/// tree. Its left edge is a drag handle that grows/shrinks the pane. Shown only
/// when the file view is enabled (View → Show File View).
class FileView extends ConsumerStatefulWidget {
  /// Width of the surrounding repository panel — used for the default (1/4) and
  /// the resize clamp.
  final double maxWidth;
  final String repoPath;
  final OpenFileCallback onOpenFile;

  const FileView({
    super.key,
    required this.maxWidth,
    required this.repoPath,
    required this.onOpenFile,
  });

  @override
  ConsumerState<FileView> createState() => _FileViewState();
}

// A visible tree row: a node plus its indentation depth.
class _Row {
  final RepoNode node;
  final int depth;
  const _Row(this.node, this.depth);
}

class _FileViewState extends ConsumerState<FileView> {
  static const _white = Color(0xFFFFFFFF);
  static const _fileWhite = Color(0xFFE4E4E6);

  // The in-flight drag width; null when not dragging. Between drags the
  // width is the persisted [PaneId.filesTree] setting (see build), falling
  // back to 1/4 of the panel when the user never chose one — so a chosen
  // width now survives remounts and restarts instead of resetting.
  double? _width;
  final Set<String> _expanded = {};
  // Lazily-loaded children of collapsed ignored dirs, keyed by dir path.
  final Map<String, List<RepoNode>> _lazyChildren = {};
  final Set<String> _lazyLoading = {};
  String? _selectedPath;
  // Auto-expand the ancestors of changed files once per repo, so work is
  // visible without hunting; further refreshes preserve the user's expansions.
  bool _autoExpanded = false;

  // Memoized flatten: the visible-row list only changes when the structure tree
  // identity changes or expansion/lazy state does (tracked by _expandRev), so a
  // status-only refresh doesn't re-walk the tree — it just recolors the rows.
  int _expandRev = 0;
  RepoNode? _rowsRoot;
  int _rowsRev = -1;
  List<_Row> _rows = const [];

  // Right-click context menu (Blame / File history), anchored at the tap point.
  final _contextMenu = ContextMenuOverlay();

  // Serializes right-click mutations (add-to-.gitignore / delete) so two can't
  // race on `.git/index.lock`; see _runMutation.
  bool _busy = false;

  // Repositions the sidebar's native vibrancy view after every frame instead
  // of via macos_window_utils's own default (a raw Timer scheduled on every
  // `build`): functionally the same continuous resync, but a bare Timer left
  // pending at a widget test's teardown trips its "no pending timers"
  // invariant, since a rebuild-heavy test never gives the very last one a
  // chance to fire before the tree is disposed. A post-frame callback runs
  // synchronously within the same pump and leaves nothing dangling.
  final _vibrancyRelay = VisualEffectSubviewContainerResizeEventRelay(
    disableUpdateOnBuild: true,
  );

  // Only resync the native vibrancy view when the pane's actual on-screen
  // size changed, not on every rebuild — a status/tree refresh rebuilds this
  // widget far more often than its geometry changes, and re-issuing the
  // native reposition call on every one of those fights the BlendMode.clear
  // hole-punch below (see output_view.dart, where this was diagnosed as the
  // cause of a flicker between opaque and transparent).
  double? _lastVibrancyWidth;

  String get repoPath => widget.repoPath;

  @override
  void dispose() {
    _contextMenu.dispose();
    super.dispose();
  }

  // Any change to the expanded/lazy sets must bump the flatten cache key.
  void _touchExpansion() => _expandRev++;

  @override
  void didUpdateWidget(FileView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repoPath != widget.repoPath) {
      // Dismiss any open right-click menu — it targets the old repo's file and
      // its actions (Blame / File history) would otherwise run against the new
      // repo once the maps below are reset out from under it.
      _contextMenu.remove();
      _expanded.clear();
      _lazyChildren.clear();
      _lazyLoading.clear();
      _selectedPath = null;
      _autoExpanded = false;
      _touchExpansion();
      _rowsRoot = null;
    }
  }

  double get _floor => 220;
  double get _ceil {
    final c = widget.maxWidth * 0.55;
    return c < _floor ? _floor : c;
  }

  List<RepoNode> _childrenOf(RepoNode node) =>
      node.lazy ? (_lazyChildren[node.path] ?? const []) : node.children;

  bool _expandable(RepoNode node) =>
      node.isDir && (node.lazy || node.children.isNotEmpty);

  void _onTap(RepoNode node) {
    if (node.isDir) {
      setState(() {
        if (_expanded.remove(node.path)) {
          // Evict a collapsed ignored-dir's lazily-loaded children instead of
          // caching them forever — expanding/collapsing many such dirs across
          // a long session would otherwise grow this map unbounded. Cheap to
          // reload from the remote if expanded again.
          if (node.lazy) {
            _lazyChildren.remove(node.path);
            _lazyLoading.remove(node.path);
          }
          _touchExpansion();
          return;
        }
        if (!_expandable(node)) return;
        _expanded.add(node.path);
        _touchExpansion();
        if (node.lazy &&
            !_lazyChildren.containsKey(node.path) &&
            !_lazyLoading.contains(node.path)) {
          _loadLazy(node.path);
        }
      });
      return;
    }
    setState(() => _selectedPath = node.path);
    final s = ref.read(repoStatusOverlayProvider(repoPath)).statusFor(node.path);
    // Fire unconditionally — a clean file (s == null) still opens, showing an
    // empty/no-changes diff, rather than silently leaving the tree highlight
    // desynced from whatever the panel was last showing.
    final untracked = s?.isUntracked ?? false;
    // A partially-staged (mixed) file is both staged and unstaged at once;
    // default to its unstaged half (the more common "what did I just edit"
    // question) — the context menu offers the staged half explicitly.
    widget.onOpenFile(
      node.path,
      staged: !untracked && (s?.isStaged ?? false) && !(s?.isUnstaged ?? false),
      untracked: untracked,
    );
  }

  // A file's right-click menu: Blame / File history, anchored at [globalPos].
  //
  // The tree pane is docked at the panel's right edge (see the class doc), so
  // a right-click near a file's right-hand text can sit close to the actual
  // window edge; opening the menu by simply extending rightward from there
  // would clip it off-window. ContextMenuController clamps the anchor so the
  // card always stays fully on screen.
  void _showContextMenu(RepoNode node, Offset globalPos) {
    // Highlight the right-clicked file (like a left-click, and like Finder) so
    // it's clear which file the menu's actions will target.
    setState(() => _selectedPath = node.path);
    final s = ref.read(repoStatusOverlayProvider(repoPath)).statusFor(node.path);
    // Only a genuinely partially-staged file needs the explicit staged/
    // unstaged toggle — a plain click already shows the only relevant half
    // for every other case.
    final mixed = s != null && !s.isUntracked && s.isStaged && s.isUnstaged;
    final untracked = s?.isUntracked ?? false;
    // Blame has nothing to attribute and there's no history to show for a
    // file git has never committed — disable both rather than letting them
    // run against a file with no history.
    const untrackedTooltip = 'Not available for untracked files';
    _contextMenu.show(context, globalPos, [
      // Open the file in the built-in viewer. Available for every file
      // regardless of git status — a viewer needs no history, unlike Blame /
      // File history below.
      ContextMenuItem(
        icon: CupertinoIcons.doc_text_viewfinder,
        label: 'View file',
        onTap: () =>
            ref.read(openFileViewersProvider.notifier).open(repoPath, node.path),
      ),
      ContextMenuItem(
        icon: CupertinoIcons.square_arrow_up,
        label: 'Open file',
        onTap: () {
          if (ref.read(connectionProvider).isLocal) {
            openFiles(['$repoPath/${node.path}']);
          } else {
            ref.read(remoteEditServiceProvider.notifier).openRemoteFile(repoPath, node.path);
          }
        },
      ),
      const ContextMenuDivider(),
      if (mixed) ...[
        ContextMenuItem(
          icon: CupertinoIcons.square_stack,
          label: 'Staged changes',
          onTap: () =>
              widget.onOpenFile(node.path, staged: true, untracked: false),
        ),
        ContextMenuItem(
          icon: CupertinoIcons.square_stack_3d_down_right,
          label: 'Unstaged changes',
          onTap: () =>
              widget.onOpenFile(node.path, staged: false, untracked: false),
        ),
      ],
      ContextMenuItem(
        icon: CupertinoIcons.person_crop_rectangle,
        label: 'Blame',
        enabled: !untracked,
        disabledTooltip: untrackedTooltip,
        onTap: () => showMacosSheet<void>(
          context: context,
          builder: (_) => EscapeDismissible(
            child: BlameSheet(repoPath: repoPath, path: node.path),
          ),
        ),
      ),
      ContextMenuItem(
        icon: CupertinoIcons.clock,
        label: 'File history',
        enabled: !untracked,
        disabledTooltip: untrackedTooltip,
        onTap: () => showMacosSheet<void>(
          context: context,
          builder: (_) => EscapeDismissible(
            child: FileHistorySheet(repoPath: repoPath, path: node.path),
          ),
        ),
      ),
      const ContextMenuDivider(),
      // Already-ignored files have nothing to add — git would just dedupe the
      // line — so the action is offered only for a not-yet-ignored file.
      if (!node.ignored)
        ContextMenuItem(
          icon: CupertinoIcons.eye_slash,
          label: 'Add to .gitignore',
          onTap: () => _addToGitignore(node.path),
        ),
      ContextMenuItem(
        icon: CupertinoIcons.trash,
        iconColor: MacosColors.systemRedColor,
        label: 'Delete File',
        onTap: () => _deleteFile(node),
      ),
    ]);
  }

  // Guards a mutation behind [_busy] (so a second right-click action can't
  // race the first on `.git/index.lock`), surfaces any failure in the standard
  // error dialog, and refreshes the tree/overlay afterward regardless of
  // outcome — mirroring RepoStatusView's own `_guardedAction`/`_run`.
  Future<void> _runMutation(Future<void> Function() op) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await runAction(context, op);
    } finally {
      if (mounted) {
        // Mark this moment so the watcher's own follow-up tick for this
        // mutation is recognized as redundant (same suppression RepoStatusView
        // relies on), then invalidate: statusProvider drives the overlay and,
        // via its structure signature, the tree; repoStructureProvider is
        // invalidated too so a deleted file leaves the tree immediately.
        ref.read(ownMutationTrackerProvider).mark(repoPath);
        ref.invalidate(statusProvider(repoPath));
        ref.invalidate(repoStructureProvider(repoPath));
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _addToGitignore(String path) =>
      _runMutation(() => ref.read(gitServiceProvider).addToGitignore(repoPath, path));

  Future<void> _deleteFile(RepoNode node) async {
    final ok = await confirmAction(
      context,
      title: 'Delete file',
      message: 'Are you sure you want to delete "${node.name}"? '
          'This action is permanent!',
      confirmLabel: 'Yes',
      cancelLabel: 'No',
      destructive: true,
    );
    if (!ok || !mounted) return;
    // Drop a stale selection highlight if the file being removed is the one
    // currently open in the diff panel.
    if (_selectedPath == node.path) {
      setState(() => _selectedPath = null);
    }
    await _runMutation(
      () => ref.read(gitServiceProvider).deleteFile(repoPath, node.path),
    );
  }

  Future<void> _loadLazy(String path) async {
    // Captured up front: this State survives a repo switch (didUpdateWidget
    // resets the maps rather than the widget being recreated), so a slower
    // request issued under a previous repo must not write into the current
    // repo's `_lazyChildren` just because it happens to share the same
    // relative directory path (e.g. both repos have a `vendor/`).
    final requestRepoPath = repoPath;
    _lazyLoading.add(path);
    try {
      final kids = await ref
          .read(gitServiceProvider)
          .listIgnoredChildren(requestRepoPath, path);
      // Also bail if the dir was collapsed (and its entry evicted) while this
      // was in flight — don't resurrect it.
      if (!mounted || requestRepoPath != repoPath || !_expanded.contains(path)) {
        return;
      }
      setState(() {
        _lazyChildren[path] = kids;
        _lazyLoading.remove(path);
        _touchExpansion();
      });
    } catch (_) {
      if (!mounted || requestRepoPath != repoPath || !_expanded.contains(path)) {
        return;
      }
      setState(() {
        _lazyChildren[path] = const [];
        _lazyLoading.remove(path);
        _touchExpansion();
      });
    }
  }

  // Flattens the visible rows, memoized on (structure identity, expansion rev)
  // so a status-only refresh reuses the same list instead of re-walking.
  List<_Row> _visibleRows(RepoNode root) {
    if (identical(root, _rowsRoot) && _rowsRev == _expandRev) return _rows;
    final rows = <_Row>[];
    void walk(RepoNode node, int depth) {
      for (final child in _childrenOf(node)) {
        rows.add(_Row(child, depth));
        if (child.isDir && _expanded.contains(child.path)) {
          walk(child, depth + 1);
        }
      }
    }

    walk(root, 0);
    _rows = rows;
    _rowsRoot = root;
    _rowsRev = _expandRev;
    return rows;
  }

  void _autoExpandDirty(RepoNode root, RepoStatusOverlay overlay) {
    final dirs = <String>{};
    void collect(RepoNode n) {
      for (final c in n.children) {
        if (!c.isDir) continue;
        if (overlay.isDirtyDir(c.path)) {
          // Expand this dir and every ancestor up to the root.
          var p = c.path;
          while (p.isNotEmpty) {
            dirs.add(p);
            final i = p.lastIndexOf('/');
            p = i < 0 ? '' : p.substring(0, i);
          }
        }
        collect(c);
      }
    }

    collect(root);
    if (dirs.isNotEmpty && mounted) {
      setState(() {
        _expanded.addAll(dirs);
        _touchExpansion();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(repoStructureProvider(repoPath));
    final overlay = ref.watch(repoStatusOverlayProvider(repoPath));
    // The stored width is clamped to THIS panel's relative bounds on render
    // only — a width chosen on a wide window renders clamped on a narrow one
    // without being overwritten (only drags persist).
    final stored = ref.watch(
      appSettingsProvider.select((s) => s.paneWidthOrNull(PaneId.filesTree)),
    );
    final width = (_width ?? stored ?? widget.maxWidth / 4)
        .clamp(_floor, _ceil)
        .toDouble();

    // See _lastVibrancyWidth's doc: resync only on an actual size change.
    if (_lastVibrancyWidth != width) {
      _lastVibrancyWidth = width;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _vibrancyRelay.onResize(),
      );
    }

    return SizedBox(
      width: width,
      // Same native NSVisualEffectView vibrancy as the sidebar (material +
      // "follows window active state" dimming), so this pane looks and
      // behaves like the nav bar rather than painting an opaque fill.
      child: TransparentMacOSSidebar(
        resizeEventRelay: _vibrancyRelay,
        // TransparentMacOSSidebar only inserts the native blur view *behind*
        // Flutter's own surface — Flutter still has to punch a hole through
        // its own canvas for it to show. BlendMode.clear does that (the same
        // trick MacosWindow's real sidebar uses internally); without it this
        // pane stays fully opaque regardless of the vibrancy view underneath.
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: Color.fromRGBO(0, 0, 0, 1.0),
            backgroundBlendMode: BlendMode.clear,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _resizeHandle(width),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _headerBar(context),
                  Container(height: 1, color: MacosColors.separatorColor),
                  // Isolated into its own compositing layer for the same
                  // reason as output_view.dart's log list: this repaints on
                  // every status/structure refresh, and without a boundary
                  // those repaints were forcing the BlendMode.clear
                  // decoration above to be re-evaluated at the same rate.
                  Expanded(
                    child: RepaintBoundary(
                      child: _body(context, async, overlay),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }

  Widget _resizeHandle(double renderedWidth) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // .down: the accepting move's delta reaches the first drag update
      // instead of being consumed as slop — no dead zone. Mirrors
      // ResizableMasterDetail.
      dragStartBehavior: DragStartBehavior.down,
      // Anchor on what is RENDERED, so a display-clamped stored width drags
      // from its on-screen position. Mirrors ResizableMasterDetail.
      onHorizontalDragStart: (_) => setState(() => _width = renderedWidth),
      onHorizontalDragUpdate: (d) {
        setState(() {
          final current = _width ?? renderedWidth;
          // Dragging left (negative dx) grows the right-docked pane.
          _width = (current - d.delta.dx).clamp(_floor, _ceil).toDouble();
        });
      },
      // Persist once per completed drag; a cancelled drag reverts (committing
      // a cancel would persist a display-clamped width — see
      // ResizableMasterDetail._discard for the full reasoning).
      onHorizontalDragEnd: (_) {
        final width = _width;
        if (width == null) return;
        ref
            .read(appSettingsProvider.notifier)
            .setPaneWidth(PaneId.filesTree, width);
        setState(() => _width = null);
      },
      onHorizontalDragCancel: () {
        if (_width != null) setState(() => _width = null);
      },
      onDoubleTap: () => ref
          .read(appSettingsProvider.notifier)
          .setPaneWidth(PaneId.filesTree, paneSpecs[PaneId.filesTree]!.defaultWidth),
      child: const MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: SizedBox(
          width: 8,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Color(0x00000000),
              border: Border(
                left: BorderSide(color: MacosColors.separatorColor),
                right: BorderSide(color: MacosColors.separatorColor),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _headerBar(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(color: Color(0x00000000)),
      padding: const EdgeInsets.fromLTRB(12, 2, 6, 2),
      child: Row(
        children: [
          Text(
            'Files',
            style: MacosTheme.of(
              context,
            ).typography.caption1.copyWith(fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          ToolIconButton(
            icon: CupertinoIcons.chevron_up_chevron_down,
            tooltip: 'Collapse all',
            size: 14,
            onPressed: () => setState(() {
              _expanded.clear();
              _touchExpansion();
            }),
          ),
          ToolIconButton(
            icon: CupertinoIcons.xmark,
            tooltip: 'Hide file view',
            size: 14,
            onPressed: () =>
                ref.read(fileViewVisibleProvider.notifier).setVisible(false),
          ),
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    AsyncValue<RepoNode> async,
    RepoStatusOverlay overlay,
  ) {
    return async.when(
      // Keep the last tree on screen while a structure refetch is in flight
      // (skipLoadingOnReload) so the pane never flashes to a spinner mid-edit.
      skipLoadingOnReload: true,
      loading: () => const Center(child: ProgressCircle()),
      error: (err, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '$err',
            style: MacosTheme.of(
              context,
            ).typography.caption1.copyWith(color: MacosColors.systemRedColor),
          ),
        ),
      ),
      data: (root) {
        // First data for this repo: reveal directories that hold work.
        if (!_autoExpanded) {
          _autoExpanded = true;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _autoExpandDirty(root, overlay),
          );
        }
        final rows = _visibleRows(root);
        if (rows.isEmpty) {
          return Center(
            child: Text(
              'Empty repository',
              style: MacosTheme.of(context).typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: rows.length,
          itemBuilder: (context, i) => _tile(context, rows[i], overlay),
        );
      },
    );
  }

  Widget _tile(BuildContext context, _Row row, RepoStatusOverlay overlay) {
    final node = row.node;
    final typography = MacosTheme.of(context).typography;
    final expanded = _expanded.contains(node.path);
    final selected = _selectedPath == node.path;
    final status = node.isDir ? null : overlay.statusFor(node.path);

    return Tappable(
      key: ValueKey(node.path),
      onTap: () => _onTap(node),
      onSecondaryTapUp: node.isDir
          ? null
          : (d) => _showContextMenu(node, d.globalPosition),
      child: Container(
        color: selected
            ? AppTheme.rowSelectionTint
            : const Color(0x00000000),
        padding: EdgeInsets.only(
          left: 8 + row.depth * 14,
          right: 8,
          top: 3,
          bottom: 3,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              child: _expandable(node)
                  ? MacosIcon(
                      expanded
                          ? CupertinoIcons.chevron_down
                          : CupertinoIcons.chevron_right,
                      size: 11,
                      color: MacosColors.systemGrayColor,
                    )
                  : null,
            ),
            _leadingIcon(node, overlay),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                node.name,
                style: typography.body.copyWith(color: _nameColor(node)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (_lazyLoading.contains(node.path)) ...[
              const SizedBox(width: 6),
              const SizedBox(
                width: 12,
                height: 12,
                child: ProgressCircle(radius: 6),
              ),
            ] else if (status != null) ...[
              const SizedBox(width: 6),
              _statusText(status),
            ],
          ],
        ),
      ),
    );
  }

  Widget _leadingIcon(RepoNode node, RepoStatusOverlay overlay) {
    if (node.isDir) {
      final color = node.ignored
          ? MacosColors.systemGrayColor
          : overlay.isDirtyDir(node.path)
          ? MacosColors.systemGreenColor
          : MacosColors.systemBlueColor;
      return MacosIcon(
        _expanded.contains(node.path)
            ? CupertinoIcons.folder_fill
            : CupertinoIcons.folder,
        size: 15,
        color: color,
      );
    }
    return const MacosIcon(
      CupertinoIcons.doc_text,
      size: 14,
      color: MacosColors.systemGrayColor,
    );
  }

  Color _nameColor(RepoNode node) {
    if (node.ignored) return MacosColors.systemGrayColor;
    return node.isDir ? _white : _fileWhite;
  }

  /// Colored status letter (no badge) for a changed file — same color
  /// convention as the working-tree list's [GitStatusBadge].
  Widget _statusText(GitFileStatus s) {
    final (letter, color) = gitStatusLetter(s);
    return Text(
      letter,
      style: TextStyle(
        color: color,
        fontSize: 12,
        fontWeight: FontWeight.w700,
        height: 1,
      ),
    );
  }
}
