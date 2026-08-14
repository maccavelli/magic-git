// Phase 0 extraction: navigator (left panel) of the branches view — pure move,
// no behavior changes.

// hide OverlayVisibilityMode: MacosTextField takes macos_ui's own enum of
// the same name (used by the filter bar's clear button).
import 'package:flutter/cupertino.dart' hide OverlayVisibilityMode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/forge/branch_forge_status.dart';
import '../../core/git/branch_comparison.dart';
import '../../core/git/branch_review_query.dart';
import '../../core/git/git_service.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/keymap.dart';
import '../../core/theme/app_theme.dart';
import '../common/context_menu.dart';
import '../common/field_styles.dart';
import '../common/inline_action_button.dart';
import '../common/label_chip.dart';
import '../common/list_keyboard_nav.dart';
import '../common/panel_shortcuts.dart';
import '../common/section_collapse.dart';
import '../common/show_more_row.dart';
import '../common/tappable.dart';
import '../common/tool_icon_button.dart';
import '../dnd/deselect.dart';
import '../dnd/drag_item.dart';
import '../forge/forge_widgets.dart' show CiDot;
import '../worktrees/worktree_tabs.dart';
import 'branch_detail.dart' show TagRemoteStatus, tagStatus;
import 'branch_row_semantics.dart';
import 'branch_view_model.dart';

// ---------------------------------------------------------------------------
// Public top-level helpers (shared with the detail pane in branches_view.dart)
// ---------------------------------------------------------------------------

/// The local branch name a remote-tracking ref [remoteShortName] (e.g.
/// `origin/feat/x`) maps to — everything after the first `/` (the remote).
String remoteLocalName(String remoteShortName) => remoteShortName.contains('/')
    ? remoteShortName.substring(remoteShortName.indexOf('/') + 1)
    : remoteShortName;

/// The three-way outcome of deleting a tag that also exists on the remote.
enum TagDeleteScope { local, both, cancel }

/// The choice offered when a branch is dropped onto the current branch's row.
enum DropOp { merge, rebase, cancel }

// ---------------------------------------------------------------------------
// Private types
// ---------------------------------------------------------------------------

/// Stable names for Branch section collapse keys (`branches.*`).
/// Matches the coordinator's identity-keyed workspace prefs storage; the
/// global `collapsedSectionsProvider` is only a legacy migration source.
abstract final class _BranchSections {
  static const pinned = 'branches.pinned';
  static const local = 'branches.local';
  static const remote = 'branches.remote';
  static const tags = 'branches.tags';
}

/// A row descriptor for the navigator's `ListView.builder` — cheap data, not a
/// built [Widget], so only the visible rows are ever constructed.
sealed class _Row {
  const _Row();
}

class _PinnedHeaderRow extends _Row {
  final int count;
  final bool collapsed;
  const _PinnedHeaderRow(this.count, {required this.collapsed});
}

class _LocalHeaderRow extends _Row {
  final String title;
  final bool collapsed;
  const _LocalHeaderRow(this.title, {required this.collapsed});
}

class _RemotesHeaderRow extends _Row {
  final String title;
  final bool collapsed;
  const _RemotesHeaderRow(this.title, {required this.collapsed});
}

class _TagsHeaderRow extends _Row {
  final String title;
  final bool collapsed;
  const _TagsHeaderRow(this.title, {required this.collapsed});
}

class _FolderRow extends _Row {
  final String path;
  final String label;
  final int depth;
  final int count;
  const _FolderRow({
    required this.path,
    required this.label,
    required this.depth,
    required this.count,
  });
}

class _BranchRow extends _Row {
  final GitRef branch;
  final bool remote;
  final int depth;
  const _BranchRow(this.branch, {required this.remote, required this.depth});
}

class _TagRefRow extends _Row {
  final GitRef tag;
  const _TagRefRow(this.tag);
}

class _StaleToggleRow extends _Row {
  final int count;
  const _StaleToggleRow(this.count);
}

class _ShowMoreTagsRow extends _Row {
  final int hidden;
  const _ShowMoreTagsRow(this.hidden);
}

class _ShowMoreRemotesRow extends _Row {
  final int hidden;
  const _ShowMoreRemotesRow(this.hidden);
}

/// The behind │ ahead divergence glyph: a small split bar whose left half fills
/// with the behind count (red) and right half with the ahead count (green),
/// each capped so a wildly-diverged branch doesn't blow out the row.
class _DivergenceBar extends StatelessWidget {
  final int ahead;
  final int behind;
  const _DivergenceBar({required this.ahead, required this.behind});

  static const double _width = 54;
  static const double _half = 27;

  double _seg(int n) {
    if (n == 0) return 0;
    // 2px minimum so a single commit still reads; scale to the half by ~20.
    return (2 + (_half - 3) * (n.clamp(0, 20) / 20)).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _width,
      height: 12,
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: Container(
                width: _seg(behind),
                height: 8,
                decoration: BoxDecoration(
                  color: MacosColors.systemRedColor.withValues(alpha: 0.85),
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(2),
                  ),
                ),
              ),
            ),
          ),
          Container(width: 1, height: 12, color: MacosColors.separatorColor),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: _seg(ahead),
                height: 8,
                decoration: BoxDecoration(
                  color: MacosColors.systemGreenColor.withValues(alpha: 0.9),
                  borderRadius: const BorderRadius.horizontal(
                    right: Radius.circular(2),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// BranchNavigator widget
// ---------------------------------------------------------------------------

/// The left panel of the branches master–detail view: toolbar, section headers,
/// local/remote/tag rows, context menus, and keyboard navigation. Pure UI —
/// all actions delegate to the parent via callbacks.
class BranchNavigator extends ConsumerStatefulWidget {
  final String repoPath;
  final BranchViewModel vm;
  final String? selectedRef;
  final bool busy;

  /// Whether this panel is the currently-visible sidebar page. It stays
  /// mounted when another page is shown, so its keyboard shortcuts must go
  /// quiet rather than fire in the background.
  final bool isActive;
  final bool grouped;
  final Set<String> collapsedFolders;
  final bool showStale;

  /// Whether hidden branches are currently revealed. Paired with
  /// [onToggleShowHidden]; the toggle is only offered when it can do
  /// something (something is hidden, or hidden rows are on screen).
  final bool showHidden;
  final BranchWorkspaceMode mode;
  final AsyncValue<BranchBaseResolution>? baseState;
  final AsyncValue<BranchReviewBatchResult>? review;
  final BranchReviewFacets facets;
  final BranchReviewSortMode reviewSort;

  /// Parsed `author:` / `status:` / plain tokens from the search field. Only
  /// meaningful in Review — Browse keeps the plain substring filter.
  final List<BranchSearchToken> searchTokens;

  /// Whether forge data can be trusted. Facets that reason about ABSENCE
  /// ("no request") must not fire on an empty-because-it-failed map.
  final bool forgeKnown;

  /// Committer identity for the "Mine" facet; null when unconfigured, which
  /// is why the facet is offered only when one of these is set.
  final String? committerEmail;
  final String? committerName;

  /// Full ref names known to conflict after an explicit Review scan.
  final Set<String> conflictRefNames;

  /// Ordered multi-selection (Review primarily; harmless in Browse).
  final BranchMultiSelection multiSelection;
  final ValueChanged<BranchMultiSelection>? onMultiSelect;
  final TextEditingController filterController;
  final FocusNode focusNode;
  final ScrollController scrollController;

  // Callbacks
  final void Function(GitRef?) onSelect;
  final void Function(GitService, GitRef) onLocalTap;
  final void Function(GitService) onCreateBranch;
  final void Function() onOpenCreateTagSheet;
  final void Function(GitService) onFetchPrune;
  final void Function(String) onToggleSection;
  final void Function(String) onToggleFolder;
  final void Function() onToggleGrouped;
  final void Function() onToggleShowStale;
  final void Function() onToggleShowHidden;
  final ValueChanged<BranchReviewFacets> onFacetsChanged;

  /// Short names currently hidden — drives the per-row Unhide entry.
  final Set<String> hiddenNames;
  final void Function(String shortName) onUnhide;
  final void Function() onShowAllTags;
  final void Function() onShowAllRemotes;
  final void Function(GitService, GitRef) onCheckout;
  final void Function(GitService, GitRef) onCheckoutRemote;
  final void Function(String) onSwitchToWorktree;
  final void Function(String) onCheckoutInNewWorktree;
  final void Function(GitService, GitRef, MergeMode) onMerge;
  final void Function(GitService, GitRef) onSetUpstream;
  final void Function(GitService, String) onUnsetUpstream;
  final void Function(GitService, String) onRenameBranch;
  final void Function(String) onTogglePin;
  final void Function(String) onCopyName;
  final void Function(GitService, String) onDeleteBranch;
  final void Function(GitService, String) onDeleteRemoteBranch;
  final void Function(GitService, GitRef, TagRemoteStatus, String?) onDeleteTag;
  final void Function(GitService, String, String) onPushTag;
  final void Function(GitService, List<String>, String) onPushAllLocalOnly;
  final void Function(
    GitService, {
    required GitRef source,
    required GitRef current,
  })
  onDropOnCurrent;
  final void Function(
    GitService, {
    required GitCommit commit,
    required GitRef branch,
  })
  onDropCommitOnBranch;

  /// Publish / create-request / open CI / compare — same actions as the detail
  /// pane, so keymap + palette handlers stay in lockstep with the buttons.
  final void Function(GitService, GitRef)? onPublish;
  final void Function(GitRef)? onCreateRequest;
  final void Function(String?)? onOpenUrl;
  final VoidCallback? onCompare;

  /// Called when the filter text changes so the coordinator can rebuild the
  /// view model with the new filter.
  final void Function(String) onFilterChanged;
  final ValueChanged<BranchWorkspaceMode> onModeChanged;
  final ValueChanged<String?> onBaseChanged;

  /// Clears a persisted user base (e.g. when the saved ref is unavailable).
  final VoidCallback onBaseReset;
  final ValueChanged<BranchReviewSortMode> onReviewSortChanged;

  const BranchNavigator({
    super.key,
    required this.repoPath,
    required this.vm,
    required this.selectedRef,
    required this.busy,
    this.isActive = true,
    required this.grouped,
    required this.collapsedFolders,
    required this.showStale,
    required this.mode,
    required this.baseState,
    required this.review,
    required this.facets,
    required this.reviewSort,
    this.searchTokens = const [],
    this.forgeKnown = false,
    this.committerEmail,
    this.committerName,
    this.conflictRefNames = const {},
    this.multiSelection = BranchMultiSelection.empty,
    this.onMultiSelect,
    required this.filterController,
    required this.focusNode,
    required this.scrollController,
    required this.onSelect,
    required this.onLocalTap,
    required this.onCreateBranch,
    required this.onOpenCreateTagSheet,
    required this.onFetchPrune,
    required this.onToggleSection,
    required this.onToggleFolder,
    required this.onToggleGrouped,
    required this.onToggleShowStale,
    required this.onToggleShowHidden,
    required this.onFacetsChanged,
    required this.onUnhide,
    this.showHidden = false,
    this.hiddenNames = const {},
    required this.onShowAllTags,
    required this.onShowAllRemotes,
    required this.onCheckout,
    required this.onCheckoutRemote,
    required this.onSwitchToWorktree,
    required this.onCheckoutInNewWorktree,
    required this.onMerge,
    required this.onSetUpstream,
    required this.onUnsetUpstream,
    required this.onRenameBranch,
    required this.onTogglePin,
    required this.onCopyName,
    required this.onDeleteBranch,
    required this.onDeleteRemoteBranch,
    required this.onDeleteTag,
    required this.onPushTag,
    required this.onPushAllLocalOnly,
    required this.onDropOnCurrent,
    required this.onDropCommitOnBranch,
    this.onPublish,
    this.onCreateRequest,
    this.onOpenUrl,
    this.onCompare,
    required this.onFilterChanged,
    required this.onModeChanged,
    required this.onBaseChanged,
    required this.onBaseReset,
    required this.onReviewSortChanged,
  });

  @override
  ConsumerState<BranchNavigator> createState() => _BranchNavigatorState();
}

class _BranchNavigatorState extends ConsumerState<BranchNavigator> {
  final _menu = ContextMenuOverlay();
  final Map<String, GlobalKey> _rowKeys = {};
  String? _selectionCursor;

  // Manual double-tap tracking for the local rows (see [_localRowBody] for why
  // not GestureDetector.onDoubleTap). A second tap on the SAME row within the
  // window checks it out.
  String? _lastTapRef;
  DateTime? _lastTapAt;
  static const Duration _doubleTapWindow = Duration(milliseconds: 400);

  @override
  void initState() {
    super.initState();
    _selectionCursor = widget.selectedRef;
  }

  @override
  void dispose() {
    _menu.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(BranchNavigator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedRef != widget.selectedRef) {
      _selectionCursor = widget.selectedRef;
    }
    if (oldWidget.repoPath != widget.repoPath) {
      _rowKeys.clear();
    }
  }

  // ---- Selection helpers --------------------------------------------------

  GlobalKey _rowKeyFor(String refName) =>
      _rowKeys.putIfAbsent(refName, GlobalKey.new);

  /// The selection when it is a LOCAL branch — what the keyboard merge/delete
  /// bindings and ↑/↓ operate on. Null when nothing (or a remote/tag) is picked.
  GitRef? get _selectedLocal {
    final name = _selectionCursor;
    if (name == null) return null;
    for (final b in widget.vm.localsOnScreen) {
      if (b.name == name) return b;
    }
    return null;
  }

  // A non-current LOCAL branch is selected — merge/delete apply (merging or
  // deleting the branch you're on is nonsensical / rejected by git).
  bool get _canActOnSelection {
    final sel = _selectedLocal;
    return sel != null && !sel.isHead;
  }

  void _select(GitRef refEntry, {bool command = false, bool shift = false}) {
    _selectionCursor = refEntry.name;
    widget.focusNode.requestFocus();
    final onMulti = widget.onMultiSelect;
    if (onMulti != null && widget.mode == BranchWorkspaceMode.review) {
      final visible = [for (final r in _visibleLocalFullRefs()) r];
      final current = widget.multiSelection;
      if (shift) {
        onMulti(current.rangeTo(refEntry.name, visible));
      } else if (command) {
        onMulti(current.toggle(refEntry.name));
      } else {
        onMulti(current.replace(refEntry.name));
      }
    }
    widget.onSelect(refEntry);
    ensureRowVisible(
      _rowKeyFor(refEntry.name),
      reduceMotion: MediaQuery.maybeOf(context)?.disableAnimations == true,
    );
  }

  /// The Review list as last shaped during build.
  ///
  /// Shift-range selection has to see EXACTLY the rows on screen. This used to
  /// be re-derived independently from the row builder, so any divergence
  /// between the two silently selected offscreen branches; now both read this.
  List<GitRef> _shapedReview = const [];

  /// Shapes the Review list: facets and search tokens filter, the sort mode
  /// orders. Browse is untouched (and stays free of forge/summary reads).
  List<GitRef> _shapeReview(BranchViewModel vm) => shapeReviewBranches(
    branches: vm.filteredLocals,
    summaries: widget.review?.value?.summariesByRefName ?? const {},
    forge: widget.forgeKnown ? vm.forge : const {},
    forgeKnown: widget.forgeKnown,
    pinnedNames: vm.pinned,
    conflictRefNames: widget.conflictRefNames,
    facets: widget.facets,
    sort: widget.reviewSort,
    search: widget.searchTokens,
    committerEmail: widget.committerEmail,
    committerName: widget.committerName,
  );

  List<String> _visibleLocalFullRefs() {
    if (widget.mode == BranchWorkspaceMode.review) {
      return [for (final b in _shapedReview) b.name];
    }
    return [for (final b in widget.vm.localsOnScreen) b.name];
  }

  void _moveSelection(int dir, {bool shift = false}) {
    final navigable = widget.vm.navigable;
    if (navigable.isEmpty) return;
    var current = -1;
    if (_selectionCursor != null) {
      for (var i = 0; i < navigable.length; i++) {
        if (navigable[i].name == _selectionCursor) {
          current = i;
          break;
        }
      }
    }
    final next = stepSelection(current, dir, navigable.length);
    _select(navigable[next], shift: shift);
  }

  /// Type-to-find buffer (does not steal focus from the filter field).
  String _typeFind = '';
  DateTime? _typeFindAt;
  static const _typeFindWindow = Duration(milliseconds: 700);

  KeyEventResult _onBranchKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !widget.isActive || widget.busy) {
      return KeyEventResult.ignored;
    }
    // Text interaction (the filter field) lives inside this Focus scope and key
    // events bubble leaf-to-root — without this gate, arrows/Enter typed into
    // the filter would drive the branch list. Same guard PanelShortcuts applies
    // to the ⌘-bindings.
    if (PanelShortcuts.textInteractionHasFocus()) {
      return KeyEventResult.ignored;
    }
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final command =
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _moveSelection(1, shift: shift);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _moveSelection(-1, shift: shift);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.home:
        _jumpSelection(0, shift: shift);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.end:
        _jumpSelection(widget.vm.navigable.length - 1, shift: shift);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.pageDown:
        _moveSelection(10, shift: shift);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.pageUp:
        _moveSelection(-10, shift: shift);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.space:
        if (widget.mode == BranchWorkspaceMode.review &&
            _selectionCursor != null) {
          final name = _selectionCursor!;
          final onMulti = widget.onMultiSelect;
          if (onMulti != null) {
            // Command-Space also toggles (parity with multi-select docs).
            onMulti(widget.multiSelection.toggle(name));
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        final sel = _selectedLocal;
        if (sel != null && !sel.isHead && sel.elsewhereWorktreePath == null) {
          widget.onCheckout(ref.read(gitServiceProvider), sel);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.contextMenu:
      case LogicalKeyboardKey.f10 when shift:
        _openContextMenuForSelection();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        // Canonical deselect — see dnd/deselect.dart for the Esc layering
        // (overlay closes first, then a live drag cancels, then this).
        return escDeselect(
          hasSelection:
              _selectionCursor != null || widget.multiSelection.isMulti,
          clear: () {
            _selectionCursor = null;
            widget.onSelect(null);
            widget.onMultiSelect?.call(BranchMultiSelection.empty);
          },
        );
      default:
        // Type-to-find: printable characters jump to the next matching row.
        if (!command && !shift && event.character != null) {
          final ch = event.character!;
          if (ch.length == 1 &&
              ch.codeUnitAt(0) >= 0x20 &&
              ch.codeUnitAt(0) != 0x7f) {
            final now = DateTime.now();
            if (_typeFindAt == null ||
                now.difference(_typeFindAt!) > _typeFindWindow) {
              _typeFind = ch.toLowerCase();
            } else {
              _typeFind += ch.toLowerCase();
            }
            _typeFindAt = now;
            _typeFindJump(_typeFind);
            return KeyEventResult.handled;
          }
        }
    }
    return KeyEventResult.ignored;
  }

  void _jumpSelection(int index, {bool shift = false}) {
    final navigable = widget.vm.navigable;
    if (navigable.isEmpty || index < 0) return;
    final i = index.clamp(0, navigable.length - 1);
    _select(navigable[i], shift: shift);
  }

  void _typeFindJump(String prefix) {
    final navigable = widget.vm.navigable;
    if (navigable.isEmpty || prefix.isEmpty) return;
    final start = () {
      if (_selectionCursor == null) return 0;
      for (var i = 0; i < navigable.length; i++) {
        if (navigable[i].name == _selectionCursor) return i + 1;
      }
      return 0;
    }();
    for (var offset = 0; offset < navigable.length; offset++) {
      final i = (start + offset) % navigable.length;
      if (navigable[i].shortName.toLowerCase().startsWith(prefix)) {
        _select(navigable[i]);
        return;
      }
    }
  }

  void _openContextMenuForSelection() {
    final name = _selectionCursor ?? widget.selectedRef;
    if (name == null) return;
    final git = ref.read(gitServiceProvider);
    GitRef? refEntry;
    for (final r in widget.vm.navigable) {
      if (r.name == name) {
        refEntry = r;
        break;
      }
    }
    if (refEntry == null) return;
    final key = _rowKeyFor(name);
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    final origin = box != null
        ? box.localToGlobal(Offset(box.size.width * 0.5, box.size.height * 0.5))
        : const Offset(200, 200);
    final entries = refEntry.isTag
        ? _tagMenu(
            git,
            refEntry,
            tagStatus(refEntry, widget.vm.remoteTags),
            widget.vm.tagRemote,
          )
        : refEntry.isRemote
        ? _remoteMenu(git, refEntry)
        : _localMenu(git, refEntry);
    _menu.show(context, origin, entries, width: 250);
  }

  /// First tap selects (immediately); a quick second tap on the same local
  /// branch also checks it out — gated exactly like the context menu's "Check
  /// out" (HEAD is already current; a branch checked out in another worktree
  /// can't be switched to here).
  void _handleLocalTap(GitService git, GitRef branch) {
    final now = DateTime.now();
    final isDouble =
        _lastTapRef == branch.name &&
        _lastTapAt != null &&
        now.difference(_lastTapAt!) < _doubleTapWindow;
    _lastTapRef = branch.name;
    _lastTapAt = now;
    final command =
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    _select(branch, command: command, shift: shift);
    if (isDouble &&
        !branch.isHead &&
        branch.elsewhereWorktreePath == null &&
        !widget.busy) {
      _lastTapRef = null; // consume — a triple tap isn't a second checkout
      widget.onLocalTap(git, branch);
    }
  }

  // ---- Row list building --------------------------------------------------

  List<_Row> _buildRows(BranchViewModel vm) {
    if (widget.mode == BranchWorkspaceMode.review) {
      final branches = _shapeReview(vm);
      _shapedReview = branches;
      return <_Row>[
        _LocalHeaderRow(
          vm.sectionTitle('Local Branches', branches.length, vm.totalLocals),
          collapsed: false,
        ),
        ..._localRows(branches),
      ];
    }
    return <_Row>[
      if (vm.pinnedLocals.isNotEmpty) ...[
        _PinnedHeaderRow(vm.pinnedLocals.length, collapsed: vm.pinnedCollapsed),
        if (!vm.pinnedCollapsed)
          for (final b in vm.pinnedLocals)
            _BranchRow(b, remote: false, depth: 0),
      ],
      _LocalHeaderRow(
        vm.sectionTitle(
          'Local Branches',
          vm.filteredLocals.length,
          vm.totalLocals,
        ),
        collapsed: vm.localCollapsed,
      ),
      if (!vm.localCollapsed) ...[
        ..._localRows(vm.activeLocals),
        if (vm.staleLocals.isNotEmpty && vm.filterLower.isEmpty)
          _StaleToggleRow(vm.staleLocals.length),
        if (vm.staleLocals.isNotEmpty &&
            (widget.showStale || vm.filterLower.isNotEmpty))
          ..._localRows(vm.staleLocals),
      ],
      _RemotesHeaderRow(
        vm.sectionTitle(
          'Remote Branches',
          vm.filteredRemotes.length,
          vm.totalRemotes,
        ),
        collapsed: vm.remoteCollapsed,
      ),
      if (!vm.remoteCollapsed) ...[
        for (final b in vm.visibleRemotes)
          _BranchRow(b, remote: true, depth: 0),
        if (vm.hiddenRemotes > 0) _ShowMoreRemotesRow(vm.hiddenRemotes),
      ],
      _TagsHeaderRow(
        vm.sectionTitle(
          'Tags',
          vm.visibleTags.length + vm.hiddenTags,
          vm.allTags.length,
        ),
        collapsed: vm.tagsCollapsed,
      ),
      if (!vm.tagsCollapsed) ...[
        for (final t in vm.visibleTags) _TagRefRow(t),
        if (vm.hiddenTags > 0) _ShowMoreTagsRow(vm.hiddenTags),
      ],
    ];
  }

  // ---- Build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final git = ref.read(gitServiceProvider);
    final keymap = ref.watch(keymapProvider);

    // One handler map for both consumers: the keyboard shortcuts and the
    // command palette's dispatched intents (see PanelShortcuts.handlers).
    // Preconditions mirror branch_detail primary/secondary gates so a
    // remapped key never does something the UI would leave disabled.
    final local = _selectedLocal;
    final remotes =
        ref.watch(remotesProvider(widget.repoPath)).value ?? const <String>[];
    final unpublished = local != null && local.upstream == null;
    final bf = local == null ? null : widget.vm.forge[local.shortName];
    final hasRequest = bf != null && bf.hasRequest;
    final canPublish =
        local != null &&
        !local.isHead &&
        unpublished &&
        remotes.isNotEmpty &&
        widget.onPublish != null &&
        !widget.busy;
    final canCreateRequest =
        local != null &&
        !local.isHead &&
        !unpublished &&
        !hasRequest &&
        widget.onCreateRequest != null &&
        !widget.busy;
    final ciUrl = bf?.ciUrl;
    final handlers = <String, VoidCallback?>{
      'branches.newBranch': () => widget.onCreateBranch(git),
      'branches.createTag': widget.onOpenCreateTagSheet,
      // Only bound with a non-current branch selected — otherwise they
      // fall through, matching the rest of the app's precondition gates.
      'branches.merge': _canActOnSelection
          ? () => widget.onMerge(git, _selectedLocal!, MergeMode.normal)
          : null,
      'branches.delete': _canActOnSelection
          ? () => widget.onDeleteBranch(git, _selectedLocal!.shortName)
          : null,
      'branches.publish': canPublish
          ? () => widget.onPublish!(git, local)
          : null,
      'branches.createRequest': canCreateRequest
          ? () => widget.onCreateRequest!(local)
          : null,
      'branches.openCi': ciUrl != null && widget.onOpenUrl != null
          ? () => widget.onOpenUrl!(ciUrl)
          : null,
      'branches.compare': local != null && widget.onCompare != null
          ? widget.onCompare
          : null,
    };

    final rows = _buildRows(widget.vm);

    return PanelShortcuts(
      bindings: widget.isActive
          ? resolveShortcuts(keymap, handlers)
          : const <ShortcutActivator, VoidCallback>{},
      handlers: widget.isActive ? handlers : const {},
      child: Focus(
        focusNode: widget.focusNode,
        onKeyEvent: _onBranchKey,
        child: Column(
          children: [
            _toolbar(git),
            Expanded(
              child: DeselectOnEmptyClick(
                onDeselect: () => widget.onSelect(null),
                child: ListView.builder(
                  controller: widget.scrollController,
                  itemCount: rows.length,
                  itemBuilder: (context, i) => _buildRow(
                    context,
                    git,
                    rows[i],
                    remoteTags: widget.vm.remoteTags,
                    tagRemote: widget.vm.tagRemote,
                    localOnly: widget.vm.localOnlyTags,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- _buildRow ----------------------------------------------------------

  Widget _buildRow(
    BuildContext context,
    GitService git,
    _Row row, {
    required Map<String, String>? remoteTags,
    required String? tagRemote,
    required List<String> localOnly,
  }) => switch (row) {
    _PinnedHeaderRow(:final count, :final collapsed) => _pinnedHeader(
      context,
      count,
      collapsed,
    ),
    _LocalHeaderRow(:final title, :final collapsed) => _localHeader(
      context,
      git,
      title,
      collapsed,
    ),
    _RemotesHeaderRow(:final title, :final collapsed) => _remotesHeader(
      context,
      git,
      title,
      collapsed,
    ),
    _TagsHeaderRow(:final title, :final collapsed) => _tagsHeader(
      context,
      git,
      title,
      localOnly,
      tagRemote,
      collapsed,
    ),
    _FolderRow(:final path, :final label, :final depth, :final count) =>
      _folderRow(context, path, label, depth, count),
    _BranchRow(:final branch, :final remote, :final depth) =>
      remote
          ? _remoteRow(context, git, branch)
          : _localRow(context, git, branch, depth),
    _TagRefRow(:final tag) => _tagRow(
      context,
      git,
      tag,
      tagStatus(tag, remoteTags),
      tagRemote,
    ),
    _StaleToggleRow(:final count) => _staleToggle(count),
    _ShowMoreTagsRow(:final hidden) => ShowMoreRow(
      label: 'Show $hidden more ${hidden == 1 ? "tag" : "tags"}',
      onTap: widget.onShowAllTags,
    ),
    _ShowMoreRemotesRow(:final hidden) => ShowMoreRow(
      label: 'Show $hidden more remote ${hidden == 1 ? "branch" : "branches"}',
      onTap: widget.onShowAllRemotes,
    ),
  };

  // ---- The toolbar (compact filter + group toggle + fetch) -----------------

  Widget _toolbar(GitService git) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CupertinoSlidingSegmentedControl<BranchWorkspaceMode>(
            groupValue: widget.mode,
            children: const {
              BranchWorkspaceMode.browse: Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('Browse'),
              ),
              BranchWorkspaceMode.review: Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('Review'),
              ),
            },
            onValueChanged: (mode) {
              if (mode != null) widget.onModeChanged(mode);
            },
          ),
          if (widget.mode == BranchWorkspaceMode.review) ...[
            const SizedBox(height: 8),
            _baseSelector(),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Sort'),
                const SizedBox(width: 8),
                Expanded(
                  child: MacosPopupButton<BranchReviewSortMode>(
                    value: widget.reviewSort,
                    items: const [
                      // Smart is the design's attention order: broken first,
                      // then requests, then unpublished/ahead, then merged.
                      // It reads forge state, so the list re-orders once when
                      // that data lands — the trade for surfacing what needs
                      // attention without the user choosing a lens.
                      MacosPopupMenuItem(
                        value: BranchReviewSortMode.smart,
                        child: Text('Smart'),
                      ),
                      MacosPopupMenuItem(
                        value: BranchReviewSortMode.activity,
                        child: Text('Activity'),
                      ),
                      MacosPopupMenuItem(
                        value: BranchReviewSortMode.name,
                        child: Text('Name'),
                      ),
                      MacosPopupMenuItem(
                        value: BranchReviewSortMode.ahead,
                        child: Text('Ahead'),
                      ),
                      MacosPopupMenuItem(
                        value: BranchReviewSortMode.behind,
                        child: Text('Behind'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) widget.onReviewSortChanged(value);
                    },
                  ),
                ),
              ],
            ),
            // Its own row: the sort popup already takes the full width at the
            // navigator's narrowest, and squeezing both in overflowed.
            const SizedBox(height: 6),
            Row(children: [Expanded(child: _facetMenu())]),
            if (_reviewStatusLabel() case final status?) ...[
              const SizedBox(height: 6),
              Text(
                status,
                style: MacosTheme.of(context).typography.caption1.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              ),
            ],
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: MacosTextField(
                  controller: widget.filterController,
                  placeholder: widget.mode == BranchWorkspaceMode.review
                      ? 'Filter local branches'
                      : 'Filter branches and tags',
                  placeholderStyle: kAppPlaceholderStyle,
                  decoration: kAppTextFieldDecoration,
                  focusedDecoration: kAppTextFieldFocusedDecoration,
                  prefix: const MacosIcon(CupertinoIcons.search, size: 14),
                  clearButtonMode: OverlayVisibilityMode.editing,
                  onChanged: widget.onFilterChanged,
                ),
              ),
              const SizedBox(width: 6),
              ToolIconButton(
                icon: widget.grouped
                    ? CupertinoIcons.list_bullet_indent
                    : CupertinoIcons.list_bullet,
                tooltip: widget.grouped
                    ? 'Grouped by folder (click for a flat list)'
                    : 'Flat list (click to group by folder)',
                size: 15,
                color: widget.grouped ? MacosColors.systemBlueColor : null,
                onPressed: widget.onToggleGrouped,
              ),
              // Offered in BOTH modes: hiding is reachable from Review, so
              // revealing must not be Review-only or a hidden branch would be
              // unrecoverable from Browse.
              if (widget.showHidden || widget.vm.hiddenLocalCount > 0) ...[
                const SizedBox(width: 2),
                ToolIconButton(
                  icon: widget.showHidden
                      ? CupertinoIcons.eye
                      : CupertinoIcons.eye_slash,
                  tooltip: widget.showHidden
                      ? 'Showing hidden branches (click to hide them again)'
                      : '${widget.vm.hiddenLocalCount} hidden '
                            '${widget.vm.hiddenLocalCount == 1 ? 'branch' : 'branches'}'
                            ' (click to show)',
                  size: 15,
                  color: widget.showHidden
                      ? MacosColors.systemBlueColor
                      : null,
                  onPressed: widget.onToggleShowHidden,
                ),
              ],
              const SizedBox(width: 2),
              ToolIconButton(
                icon: CupertinoIcons.arrow_2_circlepath,
                tooltip: 'Fetch all remotes and prune deleted branches',
                size: 15,
                onPressed: widget.busy ? null : () => widget.onFetchPrune(git),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Loading / error / partial-failure caption for the Review summary load.
  /// The facet menu: the composable filters that have no dashboard chip.
  ///
  /// Facets that reason about ABSENCE — "No request" — are offered only when
  /// forge data is actually known, because an empty-because-it-failed map
  /// would otherwise match every branch in the repo. "Mine" is offered only
  /// when a committer identity is configured, or it would silently match
  /// nothing.
  Widget _facetMenu() {
    final f = widget.facets;
    final hasIdentity =
        (widget.committerEmail?.isNotEmpty ?? false) ||
        (widget.committerName?.isNotEmpty ?? false);
    final active = f.activeCount;

    MacosPulldownMenuItem item(
      String label,
      bool selected,
      BranchReviewFacets next,
    ) => MacosPulldownMenuItem(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 16,
            child: selected
                ? const MacosIcon(CupertinoIcons.checkmark, size: 11)
                : null,
          ),
          Text(label),
        ],
      ),
      onTap: () => widget.onFacetsChanged(next),
    );

    return MacosPulldownButton(
      key: const ValueKey('branch-facet-menu'),
      title: active == 0 ? 'Filter' : 'Filter ($active)',
      items: [
        item(
          'Unpublished',
          f.unpublished,
          f.copyWith(unpublished: !f.unpublished),
        ),
        item(
          'Upstream gone',
          f.upstreamGone,
          f.copyWith(upstreamGone: !f.upstreamGone),
        ),
        item(
          'In a worktree',
          f.worktree,
          f.copyWith(worktree: !f.worktree),
        ),
        if (widget.forgeKnown) ...[
          const MacosPulldownMenuDivider(),
          item(
            'Has a request',
            f.hasRequest == true,
            f.hasRequest == true
                ? f.copyWith(clearHasRequest: true)
                : f.copyWith(hasRequest: true),
          ),
          item(
            'No request',
            f.hasRequest == false,
            f.hasRequest == false
                ? f.copyWith(clearHasRequest: true)
                : f.copyWith(hasRequest: false),
          ),
          item('Failing CI', f.failingCi, f.copyWith(failingCi: !f.failingCi)),
        ],
        if (hasIdentity) ...[
          const MacosPulldownMenuDivider(),
          item('Mine', f.mine, f.copyWith(mine: !f.mine)),
        ],
        if (active > 0) ...[
          const MacosPulldownMenuDivider(),
          MacosPulldownMenuItem(
            title: const Text('Clear filters'),
            onTap: () => widget.onFacetsChanged(const BranchReviewFacets()),
          ),
        ],
      ],
    );
  }

  String? _reviewStatusLabel() {
    final review = widget.review;
    if (review == null) {
      final base = widget.baseState;
      if (base == null || base.isLoading) return 'Resolving comparison base…';
      if (base.hasError) return 'Could not resolve a comparison base.';
      if (base.value?.base == null) return null;
      return 'Preparing base-relative summary…';
    }
    if (review.isLoading) return 'Loading base-relative summary…';
    if (review.hasError) {
      return 'Could not load base-relative summary. Try switching modes or '
          'refreshing.';
    }
    final failures = review.value?.failuresByRefName.length ?? 0;
    if (failures > 0) {
      return '$failures branch${failures == 1 ? '' : 'es'} could not be '
          'compared with the base.';
    }
    return null;
  }

  Widget _baseSelector() {
    final state = widget.baseState;
    final resolution = state?.value;
    final base = resolution?.base;
    final locals = widget.vm.allLocalBranches;
    final remotes = widget.vm.allRemoteBranches;
    final tags = widget.vm.allTags;
    final refs = [...locals, ...remotes, ...tags];
    final selected = base?.refName;
    final selectedRef = selected == null
        ? null
        : refs.where((refEntry) => refEntry.name == selected).firstOrNull;

    List<MacosPopupMenuItem<String>> section(
      String label,
      String headerValue,
      Iterable<GitRef> entries,
    ) => [
      MacosPopupMenuItem<String>(
        value: headerValue,
        enabled: false,
        child: Text(label),
      ),
      for (final refEntry in entries)
        if (refEntry.name != selected)
          MacosPopupMenuItem<String>(
            value: refEntry.name,
            child: Text(refEntry.shortName),
          ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Compared with'),
        const SizedBox(height: 4),
        SizedBox(
          width: double.infinity,
          child: MacosPopupButton<String>(
            value: selected != null && refs.any((r) => r.name == selected)
                ? selected
                : null,
            hint: Text(
              state?.hasError ?? false
                  ? 'Base unavailable'
                  : state?.isLoading ?? false
                  ? 'Resolving base…'
                  : base?.displayName ?? 'No base available',
            ),
            items: [
              if (selectedRef != null) ...[
                const MacosPopupMenuItem<String>(
                  value: '__header_recommended',
                  enabled: false,
                  child: Text('Recommended'),
                ),
                MacosPopupMenuItem(
                  value: selectedRef.name,
                  child: Text(selectedRef.shortName),
                ),
              ],
              ...section('Local', '__header_local', locals),
              ...section('Remotes', '__header_remotes', remotes),
              ...section('Tags', '__header_tags', tags),
            ],
            onChanged: (value) {
              if (value?.startsWith('__header_') ?? true) return;
              widget.onBaseChanged(value);
            },
          ),
        ),
        const SizedBox(height: 4),
        if (state?.hasError ?? false)
          const Text('Could not resolve a comparison base.')
        else if (!(state?.isLoading ?? false) && base == null)
          const Text('This repository has no commit to compare yet.')
        else if (base != null)
          Text(base.source.label),
        if (resolution?.unavailableStoredRef case final unavailable?) ...[
          Text(
            'Saved base $unavailable is unavailable; using '
            '${base?.displayName ?? 'no fallback'}.',
          ),
          const SizedBox(height: 4),
          Tappable(
            onTap: widget.onBaseReset,
            child: Text(
              'Reset saved base',
              style: MacosTheme.of(context).typography.caption1.copyWith(
                color: MacosColors.systemBlueColor,
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ---- Section headers -----------------------------------------------------

  Widget _pinnedHeader(BuildContext context, int count, bool collapsed) {
    return CollapsibleSectionHeader(
      'Pinned ($count)',
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 4),
      collapsed: collapsed,
      onToggle: () => widget.onToggleSection(_BranchSections.pinned),
      leading: const MacosIcon(
        CupertinoIcons.star_fill,
        size: 12,
        color: MacosColors.systemYellowColor,
      ),
    );
  }

  Widget _localHeader(
    BuildContext context,
    GitService git,
    String title,
    bool collapsed,
  ) {
    return CollapsibleSectionHeader(
      title,
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 4),
      collapsed: collapsed,
      onToggle: () => widget.onToggleSection(_BranchSections.local),
      trailing: [
        ToolIconButton(
          icon: CupertinoIcons.add,
          tooltip: 'New branch…',
          size: 15,
          onPressed: widget.busy ? null : () => widget.onCreateBranch(git),
        ),
      ],
    );
  }

  /// The Remote Branches section header — the fetch-and-prune affordance also
  /// lives in the toolbar; kept here too so it sits beside its own section.
  Widget _remotesHeader(
    BuildContext context,
    GitService git,
    String title,
    bool collapsed,
  ) {
    return CollapsibleSectionHeader(
      title,
      padding: const EdgeInsets.fromLTRB(16, 16, 10, 4),
      collapsed: collapsed,
      onToggle: () => widget.onToggleSection(_BranchSections.remote),
    );
  }

  /// The Tags section header — New Tag…, plus the bulk push escape hatch when
  /// the remote listing shows local-only tags.
  Widget _tagsHeader(
    BuildContext context,
    GitService git,
    String title,
    List<String> localOnly,
    String? remote,
    bool collapsed,
  ) {
    return CollapsibleSectionHeader(
      title,
      padding: const EdgeInsets.fromLTRB(16, 16, 10, 4),
      collapsed: collapsed,
      onToggle: () => widget.onToggleSection(_BranchSections.tags),
      trailing: [
        if (localOnly.isNotEmpty && remote != null) ...[
          InlineActionButton(
            label: 'Push ${localOnly.length} to $remote',
            icon: CupertinoIcons.arrow_up,
            onPressed: widget.busy
                ? null
                : () => widget.onPushAllLocalOnly(git, localOnly, remote),
          ),
          const SizedBox(width: 6),
        ],
        ToolIconButton(
          icon: CupertinoIcons.tag,
          tooltip: 'New tag…',
          size: 15,
          onPressed: widget.busy ? null : widget.onOpenCreateTagSheet,
        ),
      ],
    );
  }

  Widget _staleToggle(int count) => _staleToggleRow(count);

  Widget _staleToggleRow(int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 10, 4),
      child: Tappable(
        onTap: widget.onToggleShowStale,
        behavior: HitTestBehavior.opaque,
        child: Row(
          children: [
            MacosIcon(
              widget.showStale
                  ? CupertinoIcons.chevron_down
                  : CupertinoIcons.chevron_right,
              size: 11,
              color: MacosColors.systemGrayColor,
            ),
            const SizedBox(width: 6),
            const MacosIcon(
              CupertinoIcons.clock,
              size: 13,
              color: MacosColors.systemGrayColor,
            ),
            const SizedBox(width: 6),
            Text(
              widget.showStale
                  ? 'Hide $count stale'
                  : '$count stale (no commit in 3 months)',
              style: MacosTheme.of(context).typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Local branch rows (flat or folder-grouped) --------------------------

  /// Flattens a set of local branches into row descriptors, either flat or
  /// folder-grouped (pure shaping in [buildLocalBranchListItems]).
  List<_Row> _localRows(List<GitRef> branches) {
    final items = buildLocalBranchListItems(
      branches: branches,
      grouped: widget.grouped,
      collapsedFolderPrefixes: widget.collapsedFolders,
    );
    return [
      for (final item in items)
        switch (item) {
          LocalBranchFolderItem(
            :final path,
            :final label,
            :final depth,
            :final count,
          ) =>
            _FolderRow(path: path, label: label, depth: depth, count: count),
          LocalBranchLeafItem(:final branch, :final depth) => _BranchRow(
            branch,
            remote: false,
            depth: depth,
          ),
        },
    ];
  }

  Widget _folderRow(
    BuildContext context,
    String path,
    String label,
    int depth,
    int count,
  ) {
    final collapsed = widget.collapsedFolders.contains(path);
    final typography = MacosTheme.of(context).typography;
    return Tappable(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onToggleFolder(path),
      child: Padding(
        padding: EdgeInsets.fromLTRB(16.0 + depth * 14, 5, 10, 5),
        child: Row(
          children: [
            MacosIcon(
              collapsed
                  ? CupertinoIcons.chevron_right
                  : CupertinoIcons.chevron_down,
              size: 11,
              color: MacosColors.systemGrayColor,
            ),
            const SizedBox(width: 6),
            MacosIcon(
              collapsed ? CupertinoIcons.folder : CupertinoIcons.folder_open,
              size: 14,
              color: MacosColors.systemGrayColor,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: typography.body.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              '$count',
              style: typography.caption1.copyWith(
                color: MacosColors.systemGrayColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _localRow(
    BuildContext context,
    GitService git,
    GitRef branch,
    int depth,
  ) {
    // In grouped mode the branch shows only its leaf segment (the folder rows
    // carry the prefix); flat mode shows the full short name.
    final label = widget.grouped && branch.shortName.contains('/')
        ? branch.shortName.substring(branch.shortName.lastIndexOf('/') + 1)
        : branch.shortName;
    return KeyedSubtree(
      key: _rowKeyFor(branch.name),
      // Local branches accept a dragged commit (E2 cherry-pick onto that
      // branch). HEAD also still accepts another local branch for
      // merge-into / rebase-onto (see [_dropOnCurrent]).
      child: DragTarget<DragItem>(
        onWillAcceptWithDetails: (d) {
          if (d.data is DragCommit) {
            return branch.isLocalBranch && !branch.isCheckedOutElsewhere;
          }
          return branch.isHead &&
              d.data is DragRef &&
              (d.data as DragRef).ref.name != branch.name;
        },
        onAcceptWithDetails: (d) {
          final data = d.data;
          if (data is DragCommit) {
            widget.onDropCommitOnBranch(
              git,
              commit: data.commit,
              branch: branch,
            );
            return;
          }
          if (data is DragRef) {
            widget.onDropOnCurrent(git, source: data.ref, current: branch);
          }
        },
        builder: (context, candidate, rejected) {
          final hovering = candidate.isNotEmpty;
          final row = _localRowBody(context, git, branch, depth, label);
          if (!hovering) return row;
          return DecoratedBox(
            decoration: BoxDecoration(
              color: _accentTint,
              border: const Border(
                left: BorderSide(color: MacosColors.systemBlueColor, width: 2),
              ),
            ),
            child: row,
          );
        },
      ),
    );
  }

  static final Color _accentTint = MacosColors.systemBlueColor.withValues(
    alpha: 0.12,
  );

  Widget _localRowBody(
    BuildContext context,
    GitService git,
    GitRef branch,
    int depth,
    String label,
  ) {
    final typography = MacosTheme.of(context).typography;
    final selected =
        widget.selectedRef == branch.name ||
        widget.multiSelection.contains(branch.name);
    final elsewhere = branch.elsewhereWorktreePath;
    final navigable = widget.vm.navigable;
    final pos = navigable.indexWhere((r) => r.name == branch.name);
    final reviewSummary = widget.review?.value?.summariesByRefName[branch.name];
    final isReview = widget.mode == BranchWorkspaceMode.review;
    final isMerged = isReview
        ? reviewSummary?.mergedIntoBase ?? false
        : !branch.isHead && widget.vm.merged.contains(branch.shortName);
    final bf = widget.vm.forge[branch.shortName];
    // Selection tint wins over current-only green so HEAD is not "mask-only".
    final bg = selected
        ? AppTheme.rowSelectionTint
        : branch.isHead
        ? MacosColors.systemGreenColor.withValues(alpha: 0.12)
        : const Color(0x00000000);
    return Semantics(
      container: true,
      selected: selected,
      button: true,
      enabled: true,
      label: branchRowSemanticsLabel(
        branch: branch,
        selected: selected,
        multiSelected: widget.multiSelection.contains(branch.name),
        position: pos >= 0 ? pos + 1 : null,
        count: navigable.isEmpty ? null : navigable.length,
        forge: bf,
        merged: isMerged,
        baseDisplayName: widget.baseState?.value?.base?.displayName,
      ),
      onTap: () => _handleLocalTap(git, branch),
      child: DragItemDraggable(
        item: DragRef(branch),
        immediate: true,
        onDragSelect: () => _select(branch),
        child: Tappable(
          // Manual double-tap detection rather than GestureDetector.onDoubleTap:
          // registering onDoubleTap makes the recognizer defer EVERY single tap
          // by the ~300ms double-tap timeout (a visible select lag, and it
          // breaks tap-to-select in tests). Here the first tap selects
          // immediately and a quick second tap on the same row also checks out.
          onTap: () => _handleLocalTap(git, branch),
          onSecondaryTapUp: (d) => _menu.show(
            context,
            d.globalPosition,
            _localMenu(git, branch),
            width: 250,
          ),
          child: Container(
            color: bg,
            padding: EdgeInsets.fromLTRB(16.0 + depth * 14, 7, 12, 7),
            child: Row(
              children: [
                MacosIcon(
                  CupertinoIcons.arrow_branch,
                  size: 15,
                  color: branch.isHead
                      ? MacosColors.systemGreenColor
                      : MacosColors.systemBlueColor,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    style: typography.body.copyWith(
                      fontWeight: branch.isHead
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (elsewhere != null) ...[
                  const SizedBox(width: 6),
                  MacosTooltip(
                    message: checkedOutElsewhereMessage(elsewhere),
                    child: LabelChip(
                      elsewhere.split('/').last,
                      color: MacosColors.systemPurpleColor,
                      icon: kWorktreeIcon,
                    ),
                  ),
                ],
                const Spacer(),
                ..._forgeBadges(branch),
                _divergenceCluster(context, branch),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The trailing forge/merged signal for a local row: a grey "merged" chip
  /// (base-relative in Review, HEAD-relative in Browse), the open PR/MR
  /// number, and a CI dot — each present only when its data is in.
  List<Widget> _forgeBadges(GitRef branch) {
    final bf = widget.vm.forge[branch.shortName];
    final reviewSummary = widget.review?.value?.summariesByRefName[branch.name];
    final isReview = widget.mode == BranchWorkspaceMode.review;
    final isMerged = isReview
        ? reviewSummary?.mergedIntoBase ?? false
        : !branch.isHead && widget.vm.merged.contains(branch.shortName);
    final baseName = widget.baseState?.value?.base?.displayName;
    final currentName = widget.vm.allLocalBranches
        .where((r) => r.isHead)
        .map((r) => r.shortName)
        .firstOrNull;
    final mergedTooltip = isReview
        ? 'Merged into ${baseName ?? 'the comparison base'}'
        : 'Merged into current ${currentName ?? 'branch'}';
    return [
      if (isMerged) ...[
        MacosTooltip(
          message: mergedTooltip,
          child: const LabelChip('merged', color: MacosColors.systemGrayColor),
        ),
        const SizedBox(width: 6),
      ],
      if (bf != null && bf.hasRequest) ...[
        MacosTooltip(
          message: bf.requestDraft
              ? 'Draft ${bf.isMr ? 'merge' : 'pull'} request ${bf.requestLabel}'
              : 'Open ${bf.isMr ? 'merge' : 'pull'} request ${bf.requestLabel}',
          child: LabelChip(
            bf.requestLabel,
            color: bf.requestDraft
                ? MacosColors.systemGrayColor
                : MacosColors.systemBlueColor,
          ),
        ),
        const SizedBox(width: 6),
      ],
      if (bf?.ci != null) ...[
        MacosTooltip(
          message: 'CI: ${_ciLabel(bf!.ci!)}',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Non-color-only: glyph + color + spoken tooltip.
              Text(
                forgeCiGlyph(bf.ci!),
                style: TextStyle(
                  fontSize: 11,
                  height: 1,
                  color: _forgeCiColor(bf.ci!),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 3),
              CiDot(_forgeCiColor(bf.ci!), size: 9),
            ],
          ),
        ),
        const SizedBox(width: 6),
      ] else ...[
        // Reserve trailing status width so lazy forge badges do not jump text.
        const SizedBox(width: 28),
      ],
    ];
  }

  static Color _forgeCiColor(ForgeCi c) => switch (c) {
    ForgeCi.success => MacosColors.systemGreenColor,
    ForgeCi.failure => MacosColors.systemRedColor,
    ForgeCi.running => MacosColors.systemBlueColor,
    ForgeCi.canceled || ForgeCi.skipped => MacosColors.systemGrayColor,
    ForgeCi.unknown => MacosColors.systemOrangeColor,
  };

  static String _ciLabel(ForgeCi c) => switch (c) {
    ForgeCi.success => 'passing',
    ForgeCi.failure => 'failing',
    ForgeCi.running => 'running',
    ForgeCi.canceled => 'canceled',
    ForgeCi.skipped => 'skipped',
    ForgeCi.unknown => 'unknown',
  };

  /// The upstream-divergence signal: a compact split bar (behind │ ahead) plus
  /// the ↑n ↓n counts, or the `gone` marker when the upstream was deleted.
  Widget _divergenceCluster(BuildContext context, GitRef branch) {
    final typography = MacosTheme.of(context).typography;
    final reviewSummary = widget.review?.value?.summariesByRefName[branch.name];
    if (widget.mode == BranchWorkspaceMode.review) {
      if (reviewSummary == null) return const SizedBox.shrink();
      final ahead = reviewSummary.aheadOfBase;
      final behind = reviewSummary.behindBase;
      if (ahead == 0 && behind == 0) return const SizedBox.shrink();
      return MacosTooltip(
        message:
            '$ahead ahead, $behind behind '
            '${widget.baseState?.value?.base?.displayName ?? 'base'}',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DivergenceBar(ahead: ahead, behind: behind),
            const SizedBox(width: 6),
            Text(
              [if (ahead > 0) '↑$ahead', if (behind > 0) '↓$behind'].join(' '),
              style: typography.caption1.copyWith(
                color: MacosColors.systemBlueColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }
    if (branch.upstreamGone) {
      return MacosTooltip(
        message:
            'The upstream branch was deleted (merged or removed on the '
            'remote) — this local branch is likely stale',
        child: Text(
          'gone',
          style: typography.caption1.copyWith(
            color: MacosColors.systemOrangeColor,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    }
    if (branch.ahead == 0 && branch.behind == 0) return const SizedBox.shrink();
    return MacosTooltip(
      message:
          '${branch.ahead} commit${branch.ahead == 1 ? '' : 's'} ahead, '
          '${branch.behind} behind ${branch.upstream}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _DivergenceBar(ahead: branch.ahead, behind: branch.behind),
          const SizedBox(width: 6),
          Text(
            [
              if (branch.ahead > 0) '↑${branch.ahead}',
              if (branch.behind > 0) '↓${branch.behind}',
            ].join(' '),
            style: typography.caption1.copyWith(
              color: MacosColors.systemBlueColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _remoteRow(BuildContext context, GitService git, GitRef branch) {
    final typography = MacosTheme.of(context).typography;
    final selected = widget.selectedRef == branch.name;
    final navigable = widget.vm.navigable;
    final pos = navigable.indexWhere((r) => r.name == branch.name);
    // Keyed like [_localRow] so ↑/↓ into this section can scroll the selected
    // row into view — [ensureRowVisible] no-ops without a resolvable key, so an
    // unkeyed remote/tag row moved the selection off-screen invisibly.
    return Semantics(
      container: true,
      selected: selected,
      button: true,
      label: remoteBranchSemanticsLabel(
        branch: branch,
        selected: selected,
        position: pos >= 0 ? pos + 1 : null,
        count: navigable.isEmpty ? null : navigable.length,
      ),
      child: KeyedSubtree(
        key: _rowKeyFor(branch.name),
        child: Tappable(
          behavior: HitTestBehavior.opaque,
          onTap: () => _select(branch),
          onSecondaryTapUp: (d) => _menu.show(
            context,
            d.globalPosition,
            _remoteMenu(git, branch),
            width: 250,
          ),
          child: Container(
            color: selected
                ? AppTheme.rowSelectionTint
                : const Color(0x00000000),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            child: Row(
              children: [
                const MacosIcon(
                  CupertinoIcons.cloud,
                  size: 15,
                  color: MacosColors.systemGrayColor,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    branch.shortName,
                    style: typography.body,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tagRow(
    BuildContext context,
    GitService git,
    GitRef tag,
    TagRemoteStatus status,
    String? remote,
  ) {
    final typography = MacosTheme.of(context).typography;
    final selected = widget.selectedRef == tag.name;
    // Keyed so ↑/↓ into the Tags section scrolls the selected row into view —
    // see [_remoteRow].
    return KeyedSubtree(
      key: _rowKeyFor(tag.name),
      child: Tappable(
        behavior: HitTestBehavior.opaque,
        onTap: () => _select(tag),
        onSecondaryTapUp: (d) => _menu.show(
          context,
          d.globalPosition,
          _tagMenu(git, tag, status, remote),
          width: 250,
        ),
        child: Container(
          color: selected ? AppTheme.rowSelectionTint : const Color(0x00000000),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          child: Row(
            children: [
              const MacosIcon(
                CupertinoIcons.tag,
                size: 15,
                color: MacosColors.systemTealColor,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  tag.shortName,
                  style: typography.body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (status == TagRemoteStatus.localOnly) ...[
                const SizedBox(width: 6),
                const LabelChip(
                  'local only',
                  color: MacosColors.systemOrangeColor,
                ),
              ],
              if (status == TagRemoteStatus.differs) ...[
                const SizedBox(width: 6),
                LabelChip(
                  'differs from $remote',
                  color: MacosColors.systemRedColor,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ---- Context menus (the full action superset per ref kind) ---------------

  List<ContextMenuEntry> _localMenu(GitService git, GitRef b) {
    final elsewhere = b.elsewhereWorktreePath;
    final isPinned = widget.vm.pinned.contains(b.shortName);
    return [
      if (!b.isHead && elsewhere == null)
        ContextMenuItem(
          icon: CupertinoIcons.square_arrow_down,
          label: 'Check out',
          onTap: () => widget.onCheckout(git, b),
        ),
      if (elsewhere != null)
        ContextMenuItem(
          icon: CupertinoIcons.square_arrow_right,
          label: 'Switch to its worktree',
          onTap: () => widget.onSwitchToWorktree(elsewhere),
        ),
      ContextMenuItem(
        icon: kWorktreeIcon,
        label: 'Check out in a new worktree…',
        onTap: () => widget.onCheckoutInNewWorktree(b.shortName),
      ),
      if (!b.isHead) ...[
        const ContextMenuDivider(),
        ContextMenuItem(
          icon: CupertinoIcons.arrow_merge,
          label: 'Merge into current',
          onTap: () => widget.onMerge(git, b, MergeMode.normal),
        ),
        ContextMenuItem(
          icon: CupertinoIcons.arrow_merge,
          label: 'Merge (no fast-forward)',
          onTap: () => widget.onMerge(git, b, MergeMode.noFf),
        ),
        ContextMenuItem(
          icon: CupertinoIcons.arrow_merge,
          label: 'Merge (fast-forward only)',
          onTap: () => widget.onMerge(git, b, MergeMode.ffOnly),
        ),
        ContextMenuItem(
          icon: CupertinoIcons.arrow_merge,
          label: 'Squash merge',
          onTap: () => widget.onMerge(git, b, MergeMode.squash),
        ),
      ],
      const ContextMenuDivider(),
      ContextMenuItem(
        icon: CupertinoIcons.arrow_up_arrow_down,
        label: 'Set upstream…',
        onTap: () => widget.onSetUpstream(git, b),
      ),
      if (b.upstream != null)
        ContextMenuItem(
          icon: CupertinoIcons.arrow_up_arrow_down,
          label: 'Unset upstream',
          onTap: () => widget.onUnsetUpstream(git, b.shortName),
        ),
      ContextMenuItem(
        icon: CupertinoIcons.pencil,
        label: 'Rename…',
        onTap: () => widget.onRenameBranch(git, b.shortName),
      ),
      ContextMenuItem(
        icon: isPinned ? CupertinoIcons.star_slash : CupertinoIcons.star,
        label: isPinned ? 'Unpin' : 'Pin to top',
        onTap: () => widget.onTogglePin(b.shortName),
      ),
      // Only while hidden rows are revealed — that is the one moment a hidden
      // branch is on screen to right-click, and without it hiding would be a
      // one-way door.
      if (widget.showHidden && widget.hiddenNames.contains(b.shortName))
        ContextMenuItem(
          icon: CupertinoIcons.eye,
          label: 'Unhide',
          onTap: () => widget.onUnhide(b.shortName),
        ),
      ContextMenuItem(
        icon: CupertinoIcons.doc_on_doc,
        label: 'Copy name',
        onTap: () => widget.onCopyName(b.shortName),
      ),
      const ContextMenuDivider(),
      ContextMenuItem(
        icon: CupertinoIcons.trash,
        label: 'Delete branch',
        iconColor: MacosColors.systemRedColor,
        enabled: !b.isHead && elsewhere == null,
        disabledTooltip: b.isHead
            ? "Can't delete the branch you're on"
            : 'Checked out in the worktree "${elsewhere?.split('/').last}" '
                  '— remove that worktree first',
        onTap: () => widget.onDeleteBranch(git, b.shortName),
      ),
    ];
  }

  List<ContextMenuEntry> _remoteMenu(GitService git, GitRef b) {
    return [
      ContextMenuItem(
        icon: CupertinoIcons.square_arrow_down,
        label: 'Check out tracking branch',
        onTap: () => widget.onCheckoutRemote(git, b),
      ),
      ContextMenuItem(
        icon: CupertinoIcons.doc_on_doc,
        label: 'Copy name',
        onTap: () => widget.onCopyName(b.shortName),
      ),
      const ContextMenuDivider(),
      ContextMenuItem(
        icon: CupertinoIcons.trash,
        label: 'Delete branch on the remote',
        iconColor: MacosColors.systemRedColor,
        onTap: () => widget.onDeleteRemoteBranch(git, b.shortName),
      ),
    ];
  }

  List<ContextMenuEntry> _tagMenu(
    GitService git,
    GitRef tag,
    TagRemoteStatus status,
    String? remote,
  ) {
    return [
      if (remote != null)
        ContextMenuItem(
          icon: CupertinoIcons.cloud_upload,
          label: status == TagRemoteStatus.inSync
              ? 'Already on $remote'
              : 'Push tag to $remote',
          enabled: status != TagRemoteStatus.inSync,
          onTap: () => widget.onPushTag(git, tag.shortName, remote),
        ),
      ContextMenuItem(
        icon: CupertinoIcons.doc_on_doc,
        label: 'Copy name',
        onTap: () => widget.onCopyName(tag.shortName),
      ),
      const ContextMenuDivider(),
      ContextMenuItem(
        icon: CupertinoIcons.trash,
        label: 'Delete tag',
        iconColor: MacosColors.systemRedColor,
        onTap: () => widget.onDeleteTag(git, tag, status, remote),
      ),
    ];
  }
}
