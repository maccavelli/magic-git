import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:url_launcher/url_launcher.dart' show launchUrl;

import '../../core/forge/branch_forge_status.dart';
import '../../core/forge/forge_urls.dart';
import '../../core/git/branch_comparison.dart';
import '../../core/git/branch_review_query.dart';
import '../../core/git/git_service.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/repository_workspace_prefs.dart';
import '../../core/utils/display_error.dart';
import '../common/actions.dart';
import '../common/adaptive_workspace_layout.dart';
import '../common/branch_switch.dart';
import '../common/busy_action.dart';
import '../common/inline_action_button.dart';
import '../common/prompt_form_sheet.dart';
import '../common/prompt_text_sheet.dart';
import '../common/ref_name_validation.dart';
import '../common/repository_context.dart';
import '../common/repository_context_bar.dart';
import '../common/repository_workspace_scaffold.dart';
import '../common/section_collapse.dart';
import '../common/workspace_focus.dart';
import '../common/workspace_navigation.dart';
import '../common/workspace_preferences_binding.dart';
import '../dnd/drop_registry.dart' show DropZoneId, DropZonePage;
import '../forge/forge_create_coordinator.dart';
import '../forge/forge_prefs.dart';
import '../tabs/tab_ui_providers.dart';
import '../worktrees/add_worktree_sheet.dart';
import '../worktrees/worktree_tabs.dart';
import 'branch_bulk_delete_sheet.dart';
import 'branch_detail.dart' show BranchDetail, TagRemoteStatus;
import 'branch_navigator.dart'
    show BranchNavigator, DropOp, TagDeleteScope, remoteLocalName;
import 'branch_view_model.dart';
import 'branch_workspace_prefs.dart';
import 'create_tag_sheet.dart';
import 'pinned_branches.dart';

/// Source-control pane: local branches (checkout/delete/create), remote-tracking
/// branches, and tags. Stashes have their own top-level namespace (StashView).
///
/// Laid out as the app's canonical master–detail (like History/Forge/Stash):
/// a left navigator of branches/tags — decluttered rows, a divergence bar and
/// status badges, right-click for the full action set — beside a detail pane
/// that carries the selected ref's context and action buttons.
///
/// This coordinator owns state management and mutations. Rendering is
/// delegated to [BranchNavigator] (left panel) and [BranchDetail] (right
/// panel).
///
/// Stable names for Branch section collapse keys (`branches.*`).
///
/// When connected, collapse lives on the identity-keyed [BranchWorkspacePrefs]
/// record. The global `collapsedSectionsProvider` remains the Forge-shared
/// legacy store and the one-time migration source for `branches.*` bits only
/// (legacy global keys are never deleted).
abstract final class _BranchSections {
  static const pinned = 'branches.pinned';
  static const local = 'branches.local';
  static const remote = 'branches.remote';
  static const tags = 'branches.tags';
}

class BranchesView extends ConsumerStatefulWidget {
  final String repoPath;

  /// Whether this panel is the currently-visible sidebar page. It stays
  /// mounted when another page is shown, so its keyboard shortcuts must go
  /// quiet rather than fire in the background.
  final bool isActive;

  const BranchesView({super.key, required this.repoPath, this.isActive = true});

  @override
  ConsumerState<BranchesView> createState() => _BranchesViewState();
}

class _BranchesViewState extends ConsumerState<BranchesView>
    with BusyActionState {
  // The selected ref, by full refname (unique across branches/remotes/tags) —
  // a click selects any row (driving the detail pane); ↑/↓ walk the LOCAL
  // branches, Enter checks the selection out, ⌘⇧M / ⌘⌫ merge / delete it.
  String? _selectedRef;

  /// Whether to nest local branches into a folder tree by their `/` prefix.
  bool? _groupedOverride;

  /// Folder rows the user has collapsed (grouped mode).
  Set<String>? _collapsedFoldersOverride;
  Set<String>? _collapsedSectionsOverride;

  /// Stale local branches collapse behind a summary row.
  bool _showStale = false;

  /// Session-local override for the persisted `showHidden` preference, so the
  /// toggle responds immediately rather than waiting on the prefs round trip.
  /// Mirrors [_groupedOverride]; cleared on repo switch.
  bool? _showHiddenOverride;

  static const int _collapsedTagCount = 10;
  bool _showAllTags = false;

  static const int _collapsedRemoteCount = 25;
  bool _showAllRemotes = false;

  BranchWorkspaceMode? _modeOverride;

  /// Review facets compose by AND. The detail pane's Stale/Merged/Conflicts
  /// chips and the navigator's facet menu are two faces of this one value.
  BranchReviewFacets _facets = const BranchReviewFacets();
  BranchReviewSortMode _reviewSort = BranchReviewSortMode.smart;
  BranchMultiSelection _multiSel = BranchMultiSelection.empty;

  final _filterCtl = TextEditingController();
  final FocusNode _branchFocus = FocusNode(debugLabel: 'branch-list');
  final ScrollController _branchScroll = ScrollController();

  String get repoPath => widget.repoPath;

  @override
  void didUpdateWidget(BranchesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repoPath != widget.repoPath) {
      setState(() {
        _showAllTags = false;
        _showAllRemotes = false;
        _showStale = false;
        _showHiddenOverride = null;
        _selectedRef = null;
        _modeOverride = null;
        _facets = const BranchReviewFacets();
        _reviewSort = BranchReviewSortMode.smart;
        _multiSel = BranchMultiSelection.empty;
        _groupedOverride = null;
        _collapsedFoldersOverride = null;
        _collapsedSectionsOverride = null;
        _filterCtl.clear();
      });
      // Defer provider writes: didUpdateWidget runs mid-build and Riverpod
      // forbids notifyListeners while the tree is building.
      final oldPath = oldWidget.repoPath;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(conflictScanControllerProvider(oldPath).notifier).reset();
      });
      if (_branchScroll.hasClients) _branchScroll.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _branchFocus.dispose();
    _branchScroll.dispose();
    _filterCtl.dispose();
    super.dispose();
  }

  GitRef? _refByName(List<GitRef> all, String? name) {
    if (name == null) return null;
    for (final r in all) {
      if (r.name == name) return r;
    }
    return null;
  }

  void _toggleSection(Set<String> current, String section) {
    final next = Set<String>.from(current);
    next.contains(section) ? next.remove(section) : next.add(section);
    setState(() => _collapsedSectionsOverride = next);
    unawaited(
      _updateWorkspacePrefs((prefs) => prefs.copyWith(collapsedSections: next)),
    );
  }

  void _toggleFolder(Set<String> current, String path) {
    final next = Set<String>.from(current);
    next.contains(path) ? next.remove(path) : next.add(path);
    setState(() {
      _collapsedFoldersOverride = next;
    });
    unawaited(
      _updateWorkspacePrefs(
        (prefs) => prefs.copyWith(collapsedFolderPrefixes: next),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Build — thin coordinator
  // --------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final refsAsync = ref.watch(refsProvider(repoPath));
    return refsAsync.when(
      loading: () => const Center(child: ProgressCircle()),
      error: (err, _) => _error(context, err),
      data: (refs) => _content(context, refs),
    );
  }

  Widget _content(BuildContext context, List<GitRef> refs) {
    final git = ref.read(gitServiceProvider);
    final workspace = watchWorkspacePreferences(
      context: context,
      ref: ref,
      repositoryPath: repoPath,
      fallback: const RepositoryWorkspacePrefs(navigatorWidth: 380),
    );

    // Lazy forge + merged + pins — never block the list.
    final forgeAsync = ref.watch(branchForgeProvider(repoPath));
    final forge = forgeAsync.value ?? const {};
    final merged =
        ref.watch(mergedBranchesProvider(repoPath)).value ?? const <String>{};
    final pinned =
        ref.watch(pinnedBranchesProvider(repoPath)).value ?? const <String>{};
    final hidden =
        ref.watch(hiddenBranchesProvider(repoPath)).value ?? const <String>{};
    final showHidden =
        _showHiddenOverride ??
        ref.watch(showHiddenBranchesProvider(repoPath)).value ??
        false;
    final collapsedSections = ref.watch(collapsedSectionsProvider);
    final remoteTags = ref.watch(remoteTagsProvider(repoPath)).value;
    final remotesList = ref.watch(remotesProvider(repoPath)).value;
    final workspacePrefs = ref
        .watch(branchWorkspacePrefsProvider(repoPath))
        .value;
    final connected = ref.watch(connectionProvider).sessionEpoch > 0;
    final grouped =
        _groupedOverride ??
        (connected ? workspacePrefs?.grouped : null) ??
        false;
    final collapsedFolderPrefixes =
        _collapsedFoldersOverride ??
        (connected ? workspacePrefs?.collapsedFolderPrefixes : null) ??
        const <String>{};
    final effectiveCollapsedSections =
        _collapsedSectionsOverride ??
        (connected ? workspacePrefs?.collapsedSections : null) ??
        collapsedSections;
    final mode =
        _modeOverride ??
        (workspacePrefs?.lastMode == 'review'
            ? BranchWorkspaceMode.review
            : BranchWorkspaceMode.browse);

    final selectedRef = _refByName(refs, _selectedRef);

    // 0009 H3: apply a restored / palette-revealed ref — refs have landed by
    // definition here (_content is refsAsync's data branch). Scheduled before
    // this build's own visit callback so the restore is not re-recorded as a
    // fresh navigation.
    final pendingLocation = widget.isActive
        ? pendingWorkspaceLocation(ref, 2)
        : null;
    if (pendingLocation != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final location = takeWorkspaceLocation(ref, 2);
        if (location == null) return;
        final match = refs
            .where(
              (r) =>
                  r.name == location.identity ||
                  r.shortName == location.identity,
            )
            .firstOrNull;
        if (match == null) {
          markWorkspaceLocationUnavailable(ref, location);
          return;
        }
        setState(() => _selectedRef = match.name);
      });
    }

    // Base is needed for Review (summary + inspector) and for a selected local
    // branch's comparison tabs. Browse with no selection does not start base
    // resolution (keeps the list paint free of git discovery work).
    final needsBase =
        mode == BranchWorkspaceMode.review ||
        (selectedRef != null && selectedRef.isLocalBranch);
    final AsyncValue<BranchBaseResolution>? baseState = needsBase
        ? ref.watch(
            branchBaseProvider((
              repoPath: repoPath,
              allowForgeFetch: mode == BranchWorkspaceMode.review,
            )),
          )
        : null;

    final conflictScan = ref.watch(conflictScanControllerProvider(repoPath));
    final AsyncValue<BranchReviewBatchResult>? review;
    if (mode == BranchWorkspaceMode.review) {
      final base = baseState?.value?.base;
      if (base == null) {
        review = null;
      } else {
        final localTips = [
          for (final refEntry in refs)
            if (refEntry.isLocalBranch)
              (refName: refEntry.name, oid: refEntry.commitOid),
        ];
        review = ref.watch(
          branchReviewProvider((
            repoPath: repoPath,
            baseOid: base.oid,
            refsFingerprint: BranchRefsFingerprint(localTips),
          )),
        );
      }
    } else {
      review = null;
    }

    final reviewMode = mode == BranchWorkspaceMode.review;
    // Review-only knowledge. Browse must not watch these: its command budget
    // is asserted at zero comparison/forge work on first paint.
    final forgeKnown =
        reviewMode &&
        (ref.watch(branchForgeKnowledgeProvider(repoPath)).value?.known ??
            false);
    // The "Mine" facet matches against the configured committer identity.
    // Empty is the common case (the host's own git config is used instead),
    // and the facet is hidden rather than silently matching nothing.
    final settings = ref.watch(appSettingsProvider);
    final committerEmail = settings.committerEmail.trim().toLowerCase();
    final committerName = settings.committerName.trim().toLowerCase();

    final searchText = _filterCtl.text.trim();
    // In Review the search box speaks the token grammar (`author:`,
    // `status:`), which the shaper evaluates. Leaving the plain substring
    // pre-filter on would first match `status:stale` against branch NAMES and
    // eliminate everything before the shaper ever ran.
    final searchTokens = reviewMode
        ? parseBranchSearchQuery(searchText)
        : const <BranchSearchToken>[];

    final vm = BranchViewModel.fromRefs(
      refs: refs,
      forge: forge,
      merged: merged,
      pinned: pinned,
      collapsedSections: effectiveCollapsedSections,
      filterLower: reviewMode ? '' : searchText.toLowerCase(),
      showStale: _showStale,
      hidden: hidden,
      showHidden: showHidden,
      showAllTags: _showAllTags,
      showAllRemotes: _showAllRemotes,
      grouped: grouped,
      collapsedFolderPrefixes: collapsedFolderPrefixes,
      remoteTags: remoteTags,
      remotesList: remotesList,
      pinnedSectionKey: _BranchSections.pinned,
      localSectionKey: _BranchSections.local,
      remoteSectionKey: _BranchSections.remote,
      tagsSectionKey: _BranchSections.tags,
      collapsedTagCount: _collapsedTagCount,
      collapsedRemoteCount: _collapsedRemoteCount,
    );

    final connection = ref.watch(connectionProvider);
    final head = refs.where((item) => item.isHead).firstOrNull;
    final headForge = head == null ? null : forge[head.shortName];
    final base = baseState?.value?.base;
    final supplementKey = connection.sessionEpoch > 0
        ? RepositoryContextSupplementKey(
            repositoryIdentity: repositoryContextIdentityKey(
              backend: connection.backend.name,
              connectionId: connection.connectionId,
              repositoryPath: repoPath,
            ),
            sessionEpoch: connection.sessionEpoch,
          )
        : null;
    if (supplementKey != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref
            .read(repositoryContextSupplementCacheProvider.notifier)
            .publish(
              supplementKey,
              RepositoryContextSupplement(
                branchLabel: selectedRef == null
                    ? null
                    : 'Selected: ${selectedRef.shortName}',
                baseLabel: base == null ? null : 'Base: ${base.displayName}',
                forgeLabel: forgeAsync.value == null
                    ? null
                    : forge.isEmpty
                    ? 'No branch reviews'
                    : '${forge.length} branch review${forge.length == 1 ? '' : 's'}',
                commitPolicyBranch: head?.shortName,
                commitPolicyLabel: forgeAsync.value == null
                    ? null
                    : headForge == null
                    ? 'No open request or recent checks'
                    : [
                        if (headForge.hasRequest) headForge.requestLabel,
                        if (headForge.ci != null)
                          'checks ${headForge.ci!.name}',
                      ].join(' · '),
              ),
            );
        if (selectedRef != null) {
          ref
              .read(
                workspaceNavigationProvider(
                  WorkspaceSessionKey(repoPath, connection.sessionEpoch),
                ).notifier,
              )
              .visit(
                WorkspaceFocus(
                  repositoryPath: repoPath,
                  sessionEpoch: connection.sessionEpoch,
                  kind: selectedRef.isTag
                      ? WorkspaceFocusKind.revision
                      : WorkspaceFocusKind.branch,
                  identity: selectedRef.name,
                  secondaryIdentity: base?.refName,
                  panelIndex: 2,
                ),
              );
        }
      });
    }

    final navigator = BranchNavigator(
      repoPath: repoPath,
      vm: vm,
      selectedRef: _selectedRef,
      busy: busy,
      isActive: widget.isActive,
      grouped: grouped,
      collapsedFolders: collapsedFolderPrefixes,
      showStale: _showStale,
      mode: mode,
      baseState: baseState,
      review: review,
      facets: _facets,
      reviewSort: _reviewSort,
      searchTokens: searchTokens,
      forgeKnown: forgeKnown,
      committerEmail: committerEmail.isEmpty ? null : committerEmail,
      committerName: committerName.isEmpty ? null : committerName,
      onFacetsChanged: (next) => setState(() => _facets = next),
      conflictRefNames: conflictScan.conflictRefNames,
      filterController: _filterCtl,
      focusNode: _branchFocus,
      scrollController: _branchScroll,
      onSelect: (r) => setState(() {
        _selectedRef = r?.name;
        if (r == null) {
          _multiSel = BranchMultiSelection.empty;
        } else if (!_multiSel.isMulti) {
          _multiSel = BranchMultiSelection.empty.replace(r.name);
        }
      }),
      multiSelection: _multiSel,
      onMultiSelect: (sel) => setState(() {
        _multiSel = sel;
        _selectedRef = sel.primary;
      }),
      onLocalTap: (g, b) => _checkout(g, b.shortName),
      onCreateBranch: _createBranchPrompt,
      onOpenCreateTagSheet: _openCreateTagSheet,
      onFetchPrune: _fetchPrune,
      onToggleSection: (section) =>
          _toggleSection(effectiveCollapsedSections, section),
      onToggleFolder: (path) => _toggleFolder(collapsedFolderPrefixes, path),
      onToggleGrouped: () {
        final next = !grouped;
        setState(() => _groupedOverride = next);
        unawaited(
          _updateWorkspacePrefs((prefs) => prefs.copyWith(grouped: next)),
        );
      },
      onToggleShowStale: () => setState(() => _showStale = !_showStale),
      showHidden: showHidden,
      hiddenNames: hidden,
      onUnhide: (name) => unawaited(_unhideBranch(name)),
      onToggleShowHidden: () {
        final next = !showHidden;
        setState(() => _showHiddenOverride = next);
        unawaited(
          _updateWorkspacePrefs((prefs) => prefs.copyWith(showHidden: next)),
        );
      },
      onShowAllTags: () => setState(() => _showAllTags = true),
      onShowAllRemotes: () => setState(() => _showAllRemotes = true),
      onCheckout: (g, r) => _checkout(g, r.shortName),
      onCheckoutRemote: (g, r) => _checkoutRemote(vm, g, r),
      onSwitchToWorktree: _switchToWorktree,
      onCheckoutInNewWorktree: _checkoutInNewWorktree,
      onMerge: (g, b, mode) => _mergeBranch(g, b.shortName, mode),
      onSetUpstream: _setUpstream,
      onUnsetUpstream: _unsetUpstream,
      onRenameBranch: _renameBranch,
      onTogglePin: (branch) => _togglePin(vm, branch),
      onCopyName: _copyName,
      onDeleteBranch: (g, branch) => _deleteBranch(vm, g, branch),
      onDeleteRemoteBranch: _deleteRemoteBranch,
      onDeleteTag: _deleteTag,
      onPushTag: _pushTag,
      onPushAllLocalOnly: _pushAllLocalOnly,
      onDropOnCurrent: _dropOnCurrent,
      onDropCommitOnBranch: _dropCommitOnBranch,
      onPublish: _publishBranch,
      onCreateRequest: _createRequest,
      onOpenUrl: _open,
      onCompare: () {
        // Surface the base-relative comparison: Review mode + keep selection.
        if (mode != BranchWorkspaceMode.review) {
          _setMode(BranchWorkspaceMode.review);
        }
      },
      onFilterChanged: (_) => setState(() {}),
      onModeChanged: _setMode,
      onBaseChanged: _setBase,
      onBaseReset: _resetBase,
      onReviewSortChanged: (sort) => setState(() => _reviewSort = sort),
    );
    final detail = _multiSel.isMulti
        ? _multiSelectDetail(
            context,
            vm,
            baseState,
            git,
            busy,
            review?.value?.summariesByRefName ?? const {},
          )
        : BranchDetail(
            repoPath: repoPath,
            git: git,
            selectedRef: selectedRef,
            vm: vm,
            remoteTags: remoteTags,
            tagRemote: vm.tagRemote,
            busy: busy,
            mode: mode,
            baseState: baseState,
            review: review,
            facets: _facets,
            onFacetsChanged: (next) => setState(() => _facets = next),
            onCheckout: _checkout,
            onSwitchToWorktree: _switchToWorktree,
            onCheckoutInNewWorktree: _checkoutInNewWorktree,
            onCheckoutRemote: (g, r) => _checkoutRemote(vm, g, r),
            onMerge: _mergeBranch,
            onSetUpstream: _setUpstream,
            onRenameBranch: _renameBranch,
            onTogglePin: (branch) => _togglePin(vm, branch),
            onDeleteBranch: (g, branch) => _deleteBranch(vm, g, branch),
            onDeleteRemoteBranch: _deleteRemoteBranch,
            onDeleteTag: _deleteTag,
            onPushTag: _pushTag,
            onOpenUrl: _open,
            onPublish: _publishBranch,
            onCreateRequest: _createRequest,
            onOpenHistory: _openHistory,
            onOpenOnForge: _openOnForge,
            onCompare: () {
              if (mode != BranchWorkspaceMode.review) {
                _setMode(BranchWorkspaceMode.review);
              }
            },
          );
    final pathParts = repoPath.split('/').where((part) => part.isNotEmpty);
    final supplement = supplementKey == null
        ? null
        : ref.watch(
            repositoryContextSupplementCacheProvider.select(
              (cache) => cache[supplementKey],
            ),
          );
    final snapshot = RepositoryContextSnapshot(
      repositoryPath: repoPath,
      repositoryName:
          'Repository: ${pathParts.isEmpty ? repoPath : pathParts.last}',
      connectionLabel: connection.connectionLabel,
      hostLabel: connection.isLocal ? 'On this Mac' : connection.host,
      branchLabel: head == null ? 'Detached HEAD' : 'Branch: ${head.shortName}',
      upstreamLabel: head?.upstream,
      ahead: head?.ahead ?? 0,
      behind: head?.behind ?? 0,
      hasUpstream: head?.upstream != null,
      hasConfiguredRemote: refs.any((item) => item.isRemote),
      connected: connection.isConnected,
      busy: busy,
      refCount: refs.length,
      supplement: supplement,
    );
    return RepositoryWorkspaceScaffold(
      repositoryContext: RepositoryContextBar(
        snapshot: snapshot,
        primaryAction: RepositoryPrimaryAction(
          kind: RepositoryPrimaryActionKind.fetchAndPrune,
          label: 'Fetch & Prune',
          disabledReason: busy ? 'Another branch operation is running' : null,
        ),
        onPrimaryAction: (_) => _fetchPrune(git),
      ),
      navigator: navigator,
      canvas: detail,
      activePage: selectedRef == null
          ? CompactWorkspacePage.navigator
          : CompactWorkspacePage.canvas,
      preferences: workspace.preferences,
      onPreferencesChanged: workspace.onChanged,
      workspaceOptionsEnabled: true,
    );
  }

  Widget _multiSelectDetail(
    BuildContext context,
    BranchViewModel vm,
    AsyncValue<BranchBaseResolution>? baseState,
    GitService git,
    bool busy,
    Map<String, BranchReviewSummary> summaries,
  ) {
    final typography = MacosTheme.of(context).typography;
    final n = _multiSel.length;
    final base = baseState?.value?.base;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$n branches selected',
            style: typography.title2.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'Batch actions never include Merge. Delete only removes branches '
            'that are still ancestors of the comparison base.',
            style: typography.caption1.copyWith(
              color: MacosColors.systemGrayColor,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              InlineActionButton(
                label: 'Pin',
                icon: CupertinoIcons.pin,
                onPressed: busy ? null : () => _batchPin(vm, pin: true),
              ),
              InlineActionButton(
                label: 'Unpin',
                icon: CupertinoIcons.pin_slash,
                onPressed: busy ? null : () => _batchPin(vm, pin: false),
              ),
              InlineActionButton(
                label: 'Hide',
                icon: CupertinoIcons.eye_slash,
                onPressed: busy ? null : () => _batchHide(vm),
              ),
              InlineActionButton(
                label: 'Delete if merged…',
                icon: CupertinoIcons.trash,
                onPressed: busy || base == null
                    ? null
                    : () => _bulkDeleteSelected(vm, git, base, summaries),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _batchPin(BranchViewModel vm, {required bool pin}) async {
    final names = <String>{
      for (final full in _multiSel.ordered)
        if (full.startsWith('refs/heads/'))
          full.substring('refs/heads/'.length),
    };
    await _updateWorkspacePrefs((prefs) {
      final pins = prefs.pinnedBranchNames.toSet();
      if (pin) {
        pins.addAll(names);
      } else {
        pins.removeAll(names);
      }
      return prefs.copyWith(pinnedBranchNames: pins.toList()..sort());
    });
  }

  Future<void> _batchHide(BranchViewModel vm) async {
    final baseName = ref
        .read(branchBaseProvider((repoPath: repoPath, allowForgeFetch: false)))
        .value
        ?.base
        ?.displayName;
    final hide = <String>{};
    // Skipping silently reads as "the button did nothing" when the whole
    // selection is ineligible, so collect reasons and say so.
    final skipped = <String, String>{};
    for (final full in _multiSel.ordered) {
      if (!full.startsWith('refs/heads/')) continue;
      final short = full.substring('refs/heads/'.length);
      final refEntry = vm.allLocalBranches
          .where((r) => r.shortName == short)
          .firstOrNull;
      if (refEntry == null) continue;
      if (refEntry.isHead) {
        skipped[short] = 'current branch';
        continue;
      }
      if (refEntry.worktreePath != null ||
          refEntry.elsewhereWorktreePath != null) {
        skipped[short] = 'checked out in a worktree';
        continue;
      }
      if (vm.pinned.contains(short)) {
        skipped[short] = 'pinned';
        continue;
      }
      if (baseName != null && short == baseName) {
        skipped[short] = 'comparison base';
        continue;
      }
      hide.add(short);
    }
    if (hide.isEmpty) {
      if (skipped.isNotEmpty && mounted) {
        await showErrorDialog(
          context,
          'Nothing was hidden.\n\n'
          '${skipped.entries.map((e) => '${e.key} — ${e.value}').join('\n')}',
        );
      }
      return;
    }
    await _updateWorkspacePrefs((prefs) {
      final next = {...prefs.hiddenBranchNames, ...hide}.toList()..sort();
      return prefs.copyWith(hiddenBranchNames: next);
    });
    ref.invalidate(hiddenBranchesProvider(repoPath));
    // Keep whatever the user selected that did NOT just disappear — a mixed
    // selection where only some rows were eligible should not be wiped
    // wholesale. `preserveAfterRefresh` also re-anchors to the nearest
    // survivor so shift-range still works afterwards.
    final survivors = [
      for (final full in _multiSel.ordered)
        if (!hide.contains(
          full.startsWith('refs/heads/')
              ? full.substring('refs/heads/'.length)
              : full,
        ))
          full,
    ];
    setState(() {
      _multiSel = _multiSel.preserveAfterRefresh(survivors);
      _selectedRef = _multiSel.primary;
    });
    if (skipped.isNotEmpty && mounted) {
      await showErrorDialog(
        context,
        'Hid ${hide.length} '
        '${hide.length == 1 ? 'branch' : 'branches'}. Skipped:\n\n'
        '${skipped.entries.map((e) => '${e.key} — ${e.value}').join('\n')}',
      );
    }
  }

  /// Restores a hidden branch. Reachable only while hidden rows are shown,
  /// which is what keeps hiding reversible.
  Future<void> _unhideBranch(String shortName) async {
    await _updateWorkspacePrefs((prefs) {
      final next = prefs.hiddenBranchNames.where((n) => n != shortName).toList()
        ..sort();
      return prefs.copyWith(hiddenBranchNames: next);
    });
    ref.invalidate(hiddenBranchesProvider(repoPath));
  }

  Future<void> _bulkDeleteSelected(
    BranchViewModel vm,
    GitService git,
    BranchBase base,
    Map<String, BranchReviewSummary> summaries,
  ) async {
    // Protection is fetched lazily, only when a bulk delete is actually
    // attempted — it is a forge round trip and Browse must stay free of them.
    // An unavailable answer yields `unknown` for every branch, which the sheet
    // surfaces as a warning rather than as clearance.
    var rules = BranchProtectionRules.unavailable;
    try {
      rules = await ref.read(protectedBranchRulesProvider(repoPath).future);
    } catch (_) {
      // Already the unavailable default.
    }
    final forgeKnowledge = ref
        .read(branchForgeKnowledgeProvider(repoPath))
        .value;

    final candidates = <BulkDeleteCandidate>[];
    for (final full in _multiSel.ordered) {
      if (!full.startsWith('refs/heads/')) continue;
      final short = full.substring('refs/heads/'.length);
      final refEntry = vm.allLocalBranches
          .where((r) => r.name == full)
          .firstOrNull;
      if (refEntry == null) {
        candidates.add(
          BulkDeleteCandidate(
            branchName: short,
            fullRef: full,
            expectedOid: '',
            skipReason: 'missing',
          ),
        );
        continue;
      }
      if (refEntry.isHead) {
        candidates.add(
          BulkDeleteCandidate(
            branchName: short,
            fullRef: full,
            expectedOid: refEntry.commitOid,
            skipReason: 'current branch',
          ),
        );
        continue;
      }
      if (refEntry.worktreePath != null ||
          refEntry.elsewhereWorktreePath != null) {
        candidates.add(
          BulkDeleteCandidate(
            branchName: short,
            fullRef: full,
            expectedOid: refEntry.commitOid,
            skipReason: 'checked out in a worktree',
          ),
        );
        continue;
      }
      if (short == base.displayName || full == base.refName) {
        candidates.add(
          BulkDeleteCandidate(
            branchName: short,
            fullRef: full,
            expectedOid: refEntry.commitOid,
            skipReason: 'comparison base',
          ),
        );
        continue;
      }
      final summary = summaries[full];
      if (summary != null && !summary.mergedIntoBase) {
        candidates.add(
          BulkDeleteCandidate(
            branchName: short,
            fullRef: full,
            expectedOid: refEntry.commitOid,
            skipReason: 'not merged into base',
          ),
        );
        continue;
      }
      if (!isFullGitOid(refEntry.commitOid)) {
        candidates.add(
          BulkDeleteCandidate(
            branchName: short,
            fullRef: full,
            expectedOid: refEntry.commitOid,
            skipReason: 'incomplete OID',
          ),
        );
        continue;
      }
      final protection = rules.protectionFor(short);
      if (protection.isProtected) {
        // The server would refuse this anyway; skipping it here explains why
        // rather than letting the batch report a bare failure.
        candidates.add(
          BulkDeleteCandidate(
            branchName: short,
            fullRef: full,
            expectedOid: refEntry.commitOid,
            skipReason: 'protected on the forge',
            protection: protection,
          ),
        );
        continue;
      }
      final forge = forgeKnowledge?.known == true
          ? forgeKnowledge!.byShortName[short]
          : null;
      candidates.add(
        BulkDeleteCandidate(
          branchName: short,
          fullRef: full,
          expectedOid: refEntry.commitOid,
          aheadOfBase: summary?.aheadOfBase,
          protection: protection,
          requestLabel: forge?.hasRequest == true ? forge!.requestLabel : null,
        ),
      );
    }

    if (!mounted) return;
    final results = await showBranchBulkDeleteSheet(
      context,
      git: git,
      repoPath: repoPath,
      baseOid: base.oid,
      baseDisplayName: base.displayName,
      candidates: candidates,
    );
    if (results != null) {
      _refresh();
      setState(() {
        _multiSel = BranchMultiSelection.empty;
        _selectedRef = null;
      });
    }
  }

  // --------------------------------------------------------------------------
  // Mutation methods
  // --------------------------------------------------------------------------

  void _refresh() {
    refreshAfterMutation(ref, repoPath);
  }

  void _setMode(BranchWorkspaceMode mode) {
    setState(() {
      _modeOverride = mode;
      // Multi-selection is Review-oriented; collapse when leaving Review.
      if (mode != BranchWorkspaceMode.review) {
        _multiSel = _multiSel.primary == null
            ? BranchMultiSelection.empty
            : BranchMultiSelection.empty.replace(_multiSel.primary!);
      }
    });
    // Conflict scan is Review-only; drop results when leaving the mode.
    ref.read(conflictScanControllerProvider(repoPath).notifier).reset();
    unawaited(
      _updateWorkspacePrefs((prefs) => prefs.copyWith(lastMode: mode.name)),
    );
  }

  void _setBase(String? refName) {
    if (refName == null) return;
    ref.read(conflictScanControllerProvider(repoPath).notifier).reset();
    unawaited(
      _updateWorkspacePrefs(
        (prefs) => prefs.copyWith(selectedBaseRefName: refName),
      ),
    );
  }

  void _resetBase() {
    ref.read(conflictScanControllerProvider(repoPath).notifier).reset();
    unawaited(
      _updateWorkspacePrefs(
        (prefs) => prefs.copyWith(clearSelectedBaseRefName: true),
      ),
    );
  }

  Future<void> _updateWorkspacePrefs(
    BranchWorkspacePrefs Function(BranchWorkspacePrefs) update,
  ) async {
    final identity = await ref.read(
      repositoryUiIdentityProvider(repoPath).future,
    );
    if (identity == null) return;
    // Serialized RMW so concurrent pin/mode/base/collapse actions cannot
    // last-write-wins drop each other's fields (Phase 0 single-writer rule).
    await updateBranchWorkspacePrefs(
      identity: identity,
      legacyRepoPath: repoPath,
      globalCollapsed: await loadLegacyBranchCollapsedSections(),
      update: update,
    );
    ref.invalidate(branchWorkspacePrefsProvider(repoPath));
    ref.invalidate(pinnedBranchesProvider(repoPath));
    ref.invalidate(branchBaseProvider);
  }

  @override
  void refreshAfterAction() => _refresh();

  String? _worktreePathFor(BranchViewModel vm, String branch) {
    for (final r in vm.allLocalBranches) {
      if (r.shortName == branch) return r.worktreePath;
    }
    return null;
  }

  Future<void> _switchToWorktree(String worktreePath) =>
      switchToWorktree(context, ref, worktreePath);

  Future<void> _checkoutInNewWorktree(String branch) async {
    await showMacosSheet<void>(
      context: context,
      builder: (_) =>
          AddWorktreeSheet(repoPath: repoPath, initialCommitish: branch),
    );
    if (mounted) _refresh();
  }

  Future<void> _checkout(GitService git, String ref) async {
    await runGuarded(
      () => guardedBranchSwitch(
        context,
        this.ref,
        repoPath,
        () => git.checkout(repoPath, ref),
      ),
    );
  }

  Future<void> _checkoutRemote(
    BranchViewModel vm,
    GitService git,
    GitRef remote,
  ) async {
    final localName = remoteLocalName(remote.shortName);
    await runGuarded(
      () => guardedBranchSwitch(
        context,
        ref,
        repoPath,
        () => vm.localBranchNames.contains(localName)
            ? git.checkout(repoPath, localName)
            : git.checkoutTrackingBranch(
                repoPath,
                localName: localName,
                remoteRef: remote.shortName,
              ),
      ),
    );
  }

  void _copyName(String name) {
    Clipboard.setData(ClipboardData(text: name));
  }

  void _togglePin(BranchViewModel vm, String branch) {
    unawaited(
      setPinnedBranch(
        ref,
        repoPath,
        branch,
        pinned: !vm.pinned.contains(branch),
      ),
    );
  }

  Future<void> _createBranchPrompt(GitService git) async {
    if (busy) return;
    final startDefault = _selectedRef != null
        ? (_refByName(
                ref.read(refsProvider(repoPath)).value ?? const [],
                _selectedRef,
              )?.shortName ??
              'HEAD')
        : 'HEAD';
    final values = await promptForm(
      context,
      'New branch',
      confirmLabel: 'Create',
      fields: [
        const PromptField(
          key: 'name',
          label: 'Name',
          placeholder: 'feature/my-work',
          validate: refNameProblem,
        ),
        PromptField(
          key: 'start',
          label: 'Start at',
          placeholder: 'HEAD, branch, tag, or commit',
          initial: startDefault,
        ),
      ],
    );
    if (values == null || !mounted) return;
    final name = values['name']?.trim() ?? '';
    final start = (values['start'] ?? 'HEAD').trim();
    if (name.isEmpty) return;

    // Worktree path: open sheet with both name and start (no create-then-checkout).
    final useWorktree = await confirmAction(
      context,
      title: 'Create location',
      message:
          'Create "$name" in a new worktree instead of checking it out here?',
      confirmLabel: 'New worktree',
      cancelLabel: 'Here',
    );
    if (!mounted) return;
    if (useWorktree) {
      final created = await showMacosSheet<bool>(
        context: context,
        builder: (ctx) => AddWorktreeSheet(
          repoPath: repoPath,
          initialCommitish: start == 'HEAD' ? null : start,
          initialBranchName: name,
        ),
      );
      if (created == true) _refresh();
      return;
    }

    // Checkout after create is the default (mutually exclusive with worktree).
    if (start == 'HEAD' || start.isEmpty) {
      await runGuarded(
        () => guardedBranchSwitch(
          context,
          ref,
          repoPath,
          () => git.createBranch(repoPath, name, checkout: true),
        ),
      );
    } else {
      await runGuarded(
        () => guardedBranchSwitch(
          context,
          ref,
          repoPath,
          () => git.branchFrom(repoPath, name, start, checkout: true),
        ),
      );
    }
  }

  Future<void> _publishBranch(GitService git, GitRef branch) async {
    if (busy) return;
    final remotes =
        ref.read(remotesProvider(repoPath)).value ?? const <String>[];
    if (remotes.isEmpty) return;
    final remote = remotes.length == 1 ? remotes.first : defaultRemote(remotes);
    final ok = await confirmAction(
      context,
      title: 'Publish branch',
      message:
          'Push "${branch.shortName}" to $remote and set upstream tracking?',
      confirmLabel: 'Publish',
    );
    if (!ok || !mounted) return;
    await runGuarded(() async {
      await git.push(
        repoPath,
        remote: remote,
        branch: branch.shortName,
        setUpstream: true,
        force: PushForce.none,
      );
      // Publishing does not change tags — do not invalidate remoteTagsProvider.
    });
  }

  Future<void> _createRequest(GitRef branch) async {
    if (busy) return;
    final base = ref
        .read(branchBaseProvider((repoPath: repoPath, allowForgeFetch: false)))
        .value
        ?.base;
    await openCreateChangeRequest(
      context: context,
      ref: ref,
      branchShortName: branch.shortName,
      baseRefName: base?.refName ?? base?.displayName,
    );
  }

  /// Hands the branch off to History as a one-shot revision scope.
  ///
  /// Seeds the **main shell's** mount, not [repoPath] — this view is also
  /// embedded per-worktree (`worktrees_view.dart`), and `select`/`visit` below
  /// always drive the main shell's page stack. Seeding the worktree path from
  /// there left an intent the main `HistoryView` rejects on its mount check
  /// *without clearing it*, so the click looked inert and the stale intent was
  /// later silently consumed by that worktree's own History sub-page. Mirrors
  /// [openCreateChangeRequest]'s `forgeMountRepoPath` resolution.
  Future<void> _openHistory(GitRef branch) async {
    final mountRepoPath = ref.read(connectionProvider).repoPath;
    if (mountRepoPath == null || mountRepoPath.isEmpty) {
      await showErrorDialog(context, 'No repository is connected.');
      return;
    }
    ref
        .read(historyNavigationIntentProvider.notifier)
        .set(mountRepoPath, branch.shortName);
    ref.read(pageIndexProvider.notifier).select(DropZoneId.history.pageIndex);
    ref.read(visitedPagesProvider.notifier).visit(DropZoneId.history.pageIndex);
  }

  Future<void> _openOnForge(GitRef branch) async {
    final remoteUrl = await ref.read(originRemoteUrlProvider(repoPath).future);
    final forge = await ref.read(forgeProvider(repoPath).future);
    if (remoteUrl == null || !mounted) return;
    final url = forgeBranchWebUrl(remoteUrl, forge, branch.shortName);
    if (url == null) {
      await showErrorDialog(
        context,
        'This branch is not available on the origin-backed forge web UI.',
      );
      return;
    }
    _open(url);
  }

  Future<void> _deleteBranch(
    BranchViewModel vm,
    GitService git,
    String name,
  ) async {
    if (busy) return;
    final ok = await confirmAction(
      context,
      title: 'Delete branch',
      message: 'Delete local branch "$name"?',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await runGuarded(() async {
      try {
        await git.deleteBranch(repoPath, name);
      } on GitException catch (e) {
        if (!mounted) rethrow;
        if (e.branchHeldByWorktree) {
          final worktree = _worktreePathFor(vm, name);
          if (worktree == null) {
            if (mounted) {
              await showErrorDialog(
                context,
                'This branch is checked out in another worktree. Remove that '
                'worktree first, then delete the branch.',
              );
            }
            return;
          }
          final unmerged = !vm.merged.contains(name);
          final removeToo = await confirmAction(
            context,
            title: 'Branch is checked out in a worktree',
            message:
                'This branch is checked out in the worktree at\n$worktree\n\n'
                'Git cannot delete a branch that is checked out. Remove the '
                'worktree as well?'
                '${unmerged ? '\n\nNote: "$name" has commits not merged into '
                          'the current branch, so deleting it may discard those '
                          'commits too.' : ''}',
            confirmLabel: 'Remove Worktree and Delete',
            destructive: true,
          );
          if (!removeToo || !mounted) return;
          if (!await _removeWorktreeSafely(git, worktree) || !mounted) return;
          try {
            await git.deleteBranch(repoPath, name);
          } on GitException catch (e2) {
            if (!mounted || !e2.branchNotFullyMerged) rethrow;
            await _confirmForceDelete(git, name);
          }
          return;
        }
        if (!e.branchNotFullyMerged) rethrow;
        await _confirmForceDelete(git, name);
      }
    });
  }

  Future<bool> _removeWorktreeSafely(GitService git, String worktree) async {
    try {
      await git.removeWorktree(repoPath, worktree);
      return true;
    } on GitException catch (e) {
      if (!mounted || (!e.worktreeDirty && !e.worktreeLocked)) rethrow;
      final discard = await confirmAction(
        context,
        title: e.worktreeLocked
            ? 'Worktree is locked'
            : 'Worktree has uncommitted changes',
        message: e.worktreeLocked
            ? 'The worktree at\n$worktree\nis locked. Remove it anyway?'
            : 'The worktree at\n$worktree\nhas uncommitted changes that will '
                  'be permanently lost. Remove it and discard them?',
        confirmLabel: e.worktreeLocked ? 'Remove' : 'Discard and Remove',
        destructive: true,
      );
      if (!discard || !mounted) return false;
      await git.removeWorktree(
        repoPath,
        worktree,
        force: true,
        locked: e.worktreeLocked,
      );
      return true;
    }
  }

  Future<void> _confirmForceDelete(GitService git, String name) async {
    final force = await confirmAction(
      context,
      title: 'Branch not fully merged',
      message:
          '"$name" has commits not merged into the current branch. '
          "Force-deleting will permanently lose them unless they're "
          'reachable from elsewhere (another branch, a tag, or a stash). '
          'Force delete anyway?',
      confirmLabel: 'Force Delete',
    );
    if (!force || !mounted) return;
    await git.deleteBranch(repoPath, name, force: true);
  }

  Future<void> _mergeBranch(
    GitService git,
    String branch,
    MergeMode mode,
  ) async {
    if (busy) return;
    final message = switch (mode) {
      MergeMode.normal => 'Merge "$branch" into the current branch?',
      MergeMode.noFf =>
        'Merge "$branch" into the current branch, always creating a merge '
            'commit (--no-ff)?',
      MergeMode.ffOnly =>
        'Fast-forward the current branch to "$branch" (--ff-only)?',
      MergeMode.squash =>
        'Squash-merge "$branch": stage its combined changes without '
            'committing?',
    };
    final ok = await confirmAction(
      context,
      title: 'Merge branch',
      message: message,
      confirmLabel: 'Merge',
    );
    if (!ok) return;
    await _runMerge(git, branch, mode);
  }

  Future<void> _runMerge(GitService git, String branch, MergeMode mode) async {
    final label = [
      'git merge',
      if (mode == MergeMode.noFf) '--no-ff',
      if (mode == MergeMode.ffOnly) '--ff-only',
      if (mode == MergeMode.squash) '--squash',
      branch,
    ].join(' ');
    await runLogged(
      label,
      (log) async =>
          log.logResult(label, await git.merge(repoPath, branch, mode: mode)),
    );
  }

  Future<void> _runRebaseOnto(GitService git, String onto) async {
    final label = 'git rebase $onto';
    await runLogged(
      label,
      (log) async => log.logResult(label, await git.rebaseOnto(repoPath, onto)),
      dock: true,
    );
  }

  Future<void> _dropOnCurrent(
    GitService git, {
    required GitRef source,
    required GitRef current,
  }) async {
    if (busy || !source.isLocalBranch || source.name == current.name) return;
    final op = await chooseAction<DropOp>(
      context,
      title: 'Combine with ${current.shortName}',
      message: 'Bring "${source.shortName}" and the current branch together.',
      primaryLabel: 'Merge "${source.shortName}" into "${current.shortName}"',
      primaryValue: DropOp.merge,
      secondary: [
        (
          'Rebase "${current.shortName}" onto "${source.shortName}"',
          DropOp.rebase,
        ),
        ('Cancel', DropOp.cancel),
      ],
    );
    if (op == null || op == DropOp.cancel || !mounted) return;
    final g = ref.read(gitServiceProvider);
    if (op == DropOp.merge) {
      await _runMerge(g, source.shortName, MergeMode.normal);
    } else {
      await _runRebaseOnto(g, source.shortName);
    }
  }

  Future<void> _dropCommitOnBranch(
    GitService git, {
    required GitCommit commit,
    required GitRef branch,
  }) async {
    if (busy || !branch.isLocalBranch || branch.isCheckedOutElsewhere) return;
    final ok = await confirmAction(
      context,
      title: 'Cherry-pick onto ${branch.shortName}',
      message:
          'Apply ${commit.shortHash} onto "${branch.shortName}"?'
          '${branch.isHead ? '' : ' This checks out the branch first.'}',
      confirmLabel: 'Cherry-pick',
    );
    if (!ok || !mounted) return;

    int? mainline;
    if (commit.isMerge) {
      final v = await promptText(
        context,
        'Mainline parent',
        placeholder: '1',
        initial: '1',
        description:
            'This is a merge commit — pick which parent counts as the '
            'mainline (1 = the branch that was merged into).',
      );
      if (v == null || !mounted) return;
      mainline = int.tryParse(v) ?? 1;
    }

    final label = 'git cherry-pick ${commit.shortHash}';
    if (!branch.isHead) {
      final switched = await runGuarded(
        () => guardedBranchSwitch(
          context,
          ref,
          repoPath,
          () => git.checkout(repoPath, branch.shortName),
        ),
      );
      if (!switched || !mounted) return;
    }
    await runLogged(label, (log) async {
      log.logResult(
        label,
        await git.cherryPick(repoPath, commit.hash, mainline: mainline),
      );
    });
  }

  Future<void> _openCreateTagSheet() async {
    final created = await showMacosSheet<bool>(
      context: context,
      builder: (_) => CreateTagSheet(repoPath: repoPath),
    );
    if (created == true && mounted) _refresh();
  }

  void _open(String? url) {
    if (url != null && url.isNotEmpty) {
      unawaited(launchUrl(Uri.parse(url)));
    }
  }

  Future<void> _pushTag(GitService git, String name, String remote) async {
    final label = 'git push $remote refs/tags/$name';
    await runLogged(label, (log) async {
      log.logResult(label, await git.pushTag(repoPath, name, remote: remote));
    }, dock: true);
    if (mounted) refreshRemoteTags(ref, repoPath);
  }

  Future<void> _deleteTag(
    GitService git,
    GitRef tag,
    TagRemoteStatus status,
    String? remote,
  ) async {
    final name = tag.shortName;
    final knownOnRemote =
        status == TagRemoteStatus.inSync || status == TagRemoteStatus.differs;
    if (knownOnRemote && remote != null) {
      final choice = await chooseAction<TagDeleteScope>(
        context,
        title: 'Delete tag',
        message:
            'Tag "$name" also exists on "$remote". Deleting it there removes '
            'it for everyone who uses the remote — the local delete is '
            'undoable (⌘Z), the remote one is not.',
        primaryLabel: 'Delete Local Only',
        primaryValue: TagDeleteScope.local,
        secondary: [
          ('Delete Local and on $remote', TagDeleteScope.both),
          ('Cancel', TagDeleteScope.cancel),
        ],
      );
      if (choice == null || choice == TagDeleteScope.cancel || !mounted) {
        return;
      }
      final deletedLocally = await runGuarded(
        () => git.deleteTag(repoPath, name),
      );
      if (deletedLocally && choice == TagDeleteScope.both && mounted) {
        await runLogged('git push --delete', (log) async {
          log.logResult(
            'git push --delete $remote refs/tags/$name',
            await git.deleteRemoteTag(repoPath, remote, name),
          );
        }, dock: true);
        if (mounted) refreshRemoteTags(ref, repoPath);
      }
      return;
    }
    final ok = await confirmAction(
      context,
      title: 'Delete tag',
      message: 'Delete local tag "$name"?',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (ok && mounted) {
      await runGuarded(() => git.deleteTag(repoPath, name));
    }
  }

  Future<void> _pushAllLocalOnly(
    GitService git,
    List<String> names,
    String remote,
  ) async {
    final listing = names.length <= 8 ? '\n\n${names.join(', ')}' : '';
    final ok = await confirmAction(
      context,
      title: 'Push tags',
      message:
          'Push ${names.length} tag(s) that exist only locally to '
          '"$remote"?$listing',
      confirmLabel: 'Push',
    );
    if (!ok || !mounted) return;
    await runLogged('git push tags', (log) async {
      log.logResult(
        'git push $remote ${names.map((n) => 'refs/tags/$n').join(' ')}',
        await git.pushTags(repoPath, names, remote: remote),
      );
    }, dock: true);
    if (mounted) refreshRemoteTags(ref, repoPath);
  }

  Future<void> _deleteRemoteBranch(GitService git, String shortName) async {
    final slash = shortName.indexOf('/');
    if (slash <= 0) return;
    final remote = shortName.substring(0, slash);
    final branch = shortName.substring(slash + 1);
    final ok = await confirmAction(
      context,
      title: 'Delete remote branch',
      message:
          'Delete "$branch" on "$remote"? This removes it for everyone who '
          'uses the remote, and it cannot be undone from here.',
      confirmLabel: 'Delete on Remote',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await runLogged('git push --delete', (log) async {
      log.logResult(
        'git push --delete $remote $branch',
        await git.deleteRemoteBranch(repoPath, remote, branch),
      );
    }, dock: true);
  }

  Future<void> _setUpstream(GitService git, GitRef branch) async {
    if (busy) return;
    final name = branch.shortName;
    final target = await promptText(
      context,
      'Set upstream',
      placeholder: 'origin/$name',
      initial: branch.upstream ?? 'origin/$name',
      description:
          'The remote-tracking branch (remote/branch) that pull, push, and '
          'the ahead/behind badges follow.',
      confirmLabel: 'Set Upstream',
      validate: refNameProblem,
    );
    if (target == null || !mounted) return;
    await runGuarded(() => git.setUpstream(repoPath, name, target));
  }

  Future<void> _unsetUpstream(GitService git, String name) async {
    if (busy) return;
    await runGuarded(() => git.unsetUpstream(repoPath, name));
  }

  Future<void> _fetchPrune(GitService git) async {
    await runLogged('git fetch --all --prune', (log) async {
      log.logResult('git fetch --all --prune', await git.fetch(repoPath));
    }, dock: true);
    if (mounted) refreshRemoteTags(ref, repoPath);
  }

  Future<void> _renameBranch(GitService git, String oldName) async {
    final newName = await promptText(
      context,
      'Rename branch',
      placeholder: 'new name',
      initial: oldName,
      validate: refNameProblem,
    );
    if (newName == null || newName == oldName || !mounted) return;
    await runGuarded(() => git.renameBranch(repoPath, oldName, newName));
    if (mounted && _selectedRef == 'refs/heads/$oldName') {
      setState(() => _selectedRef = 'refs/heads/$newName');
    }
  }

  Widget _error(BuildContext context, Object err) => Padding(
    padding: const EdgeInsets.all(16),
    child: Text(
      displayError(err),
      style: MacosTheme.of(
        context,
      ).typography.body.copyWith(color: MacosColors.systemRedColor),
    ),
  );
}
