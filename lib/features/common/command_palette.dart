import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/forge/forge.dart';
import '../../core/git/git_service.dart';
import '../../core/output/output_log.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/keymap.dart';
import '../../core/storage/saved_connection.dart';
import '../../core/storage/saved_workspace_set.dart';
import '../tabs/tabs_controller.dart';
import '../worktrees/worktree_tabs.dart';
import 'field_styles.dart';
import 'palette_models.dart';
import 'palette_row_semantics.dart';
import 'panel_actions.dart';
import 'sized_sheet.dart';
import 'tappable.dart';

/// The four buckets every palette command sorts into, VS Code-style: typing
/// `git: pu` narrows to the git category, and every row wears its category as
/// a colored chip so the (large) flat list stays scannable.
enum PaletteCategory {
  /// Navigation: panels, windows, worktrees.
  go('go', MacosColors.systemBlueColor),

  /// Local git operations: sync, staging, commits, branches, tags, stashes,
  /// history actions, recovery.
  git('git', MacosColors.systemGreenColor),

  /// GitHub / GitLab: pull/merge requests, CI.
  forge('forge', MacosColors.systemPurpleColor),

  /// The app itself: views, appearance, settings, connections, workspace.
  app('app', MacosColors.systemOrangeColor);

  /// The typed prefix (`git:`) and the chip text.
  final String prefix;
  final Color color;
  const PaletteCategory(this.prefix, this.color);

  /// The category whose prefix is exactly [token] (case-insensitive), if any.
  static PaletteCategory? byPrefix(String token) {
    final t = token.trim().toLowerCase();
    for (final c in values) {
      if (c.prefix == t) return c;
    }
    return null;
  }
}

/// One runnable entry in the [CommandPalette]. [run] is invoked *after* the
/// palette has closed, so it must not depend on the palette's own context — the
/// closures here call back into the app shell (whose context is stable), into
/// notifiers captured up front, or dispatch a [PaletteIntent] at a panel.
class PaletteCommand {
  final IconData icon;
  final String label;
  final PaletteCategory category;
  final PaletteEntry entry;

  /// The action's current keyboard shortcut, when it has one — shown as a
  /// right-aligned hint so the palette doubles as shortcut discovery.
  final String? shortcut;
  final VoidCallback run;
  PaletteCommand({
    required this.icon,
    required this.label,
    required this.category,
    required this.run,
    this.shortcut,
    PaletteEntry? entry,
  }) : entry =
           entry ??
           ActionPaletteEntry(
             id: 'action:${category.prefix}:${label.toLowerCase()}',
             primaryLabel: label,
             category: switch (category) {
               PaletteCategory.go => PaletteQueryScope.go,
               PaletteCategory.git => PaletteQueryScope.git,
               PaletteCategory.forge => PaletteQueryScope.forge,
               PaletteCategory.app => PaletteQueryScope.app,
             },
           );
}

void _noopSavedWorkspaces() {}
void _noopWorkspaceSet(SavedWorkspaceSet _) {}

/// Palette metadata for a keymap-registered, panel-scoped action: where it
/// lives (so the palette can switch there) and how it reads in the list. The
/// label comes from [kKeymapActionsById] — one source of truth with the
/// Keyboard Shortcuts sheet.
class _ActionSpec {
  final String id;
  final PaletteCategory category;
  final IconData icon;
  const _ActionSpec(this.id, this.category, this.icon);

  /// Where the action lives, from the one routing table the menu bar also
  /// reads — so the palette and a native menu item can never disagree about
  /// which panel owns a command.
  int? get panelIndex => panelOwnerOf(id);
}

/// Every panel-scoped keymap action the palette offers, in display order.
///
/// Deliberate exclusions: `global.*` (the shell handles those directly — the
/// panel switches are the palette's own "Go to" rows), `commit.*` (only
/// meaningful inside the commit sheet) and `viewer.*` (scoped to a viewer
/// window the palette can't address).
const List<_ActionSpec> _panelActions = [
  // Repository (panel 0) — sync + staging + commit.
  _ActionSpec(
    'repository.fetch',
    PaletteCategory.git,
    CupertinoIcons.cloud_download,
  ),
  _ActionSpec(
    'repository.pull',
    PaletteCategory.git,
    CupertinoIcons.arrow_down_circle,
  ),
  _ActionSpec(
    'repository.push',
    PaletteCategory.git,
    CupertinoIcons.arrow_up_circle,
  ),
  _ActionSpec(
    'repository.sync',
    PaletteCategory.git,
    CupertinoIcons.arrow_2_circlepath,
  ),
  _ActionSpec(
    'repository.forcePush',
    PaletteCategory.git,
    CupertinoIcons.arrow_up_circle_fill,
  ),
  _ActionSpec(
    'repository.stageAll',
    PaletteCategory.git,
    CupertinoIcons.tray_arrow_down,
  ),
  _ActionSpec(
    'repository.toggleStage',
    PaletteCategory.git,
    CupertinoIcons.tray_arrow_down_fill,
  ),
  _ActionSpec('repository.discard', PaletteCategory.git, CupertinoIcons.trash),
  _ActionSpec(
    'repository.focusCommit',
    PaletteCategory.git,
    CupertinoIcons.checkmark_seal,
  ),
  _ActionSpec('repository.stash', PaletteCategory.git, CupertinoIcons.tray_2),
  // History (panel 1) — commit-level operations.
  _ActionSpec('history.filter', PaletteCategory.git, CupertinoIcons.search),
  _ActionSpec(
    'history.copySha',
    PaletteCategory.git,
    CupertinoIcons.doc_on_clipboard,
  ),
  _ActionSpec(
    'history.checkout',
    PaletteCategory.git,
    CupertinoIcons.arrow_branch,
  ),
  _ActionSpec(
    'history.branchFrom',
    PaletteCategory.git,
    CupertinoIcons.arrow_branch,
  ),
  _ActionSpec(
    'history.cherryPick',
    PaletteCategory.git,
    CupertinoIcons.arrow_merge,
  ),
  _ActionSpec(
    'history.rebaseFrom',
    PaletteCategory.git,
    CupertinoIcons.arrow_swap,
  ),
  _ActionSpec(
    'history.amend',
    PaletteCategory.git,
    CupertinoIcons.pencil_circle,
  ),
  // Branches (panel 2).
  _ActionSpec(
    'branches.newBranch',
    PaletteCategory.git,
    CupertinoIcons.plus_circle,
  ),
  _ActionSpec('branches.createTag', PaletteCategory.git, CupertinoIcons.tag),
  _ActionSpec(
    'branches.merge',
    PaletteCategory.git,
    CupertinoIcons.arrow_merge,
  ),
  _ActionSpec('branches.delete', PaletteCategory.git, CupertinoIcons.trash),
  _ActionSpec(
    'branches.publish',
    PaletteCategory.git,
    CupertinoIcons.cloud_upload,
  ),
  _ActionSpec(
    'branches.createRequest',
    PaletteCategory.forge,
    CupertinoIcons.plus_rectangle_on_rectangle,
  ),
  _ActionSpec('branches.openCi', PaletteCategory.forge, CupertinoIcons.gauge),
  _ActionSpec('branches.compare', PaletteCategory.git, CupertinoIcons.doc_text),
  // Stashes (panel 3).
  _ActionSpec(
    'stashes.apply',
    PaletteCategory.git,
    CupertinoIcons.tray_arrow_up,
  ),
  _ActionSpec(
    'stashes.pop',
    PaletteCategory.git,
    CupertinoIcons.tray_arrow_up_fill,
  ),
  _ActionSpec('stashes.drop', PaletteCategory.git, CupertinoIcons.trash),
  _ActionSpec(
    'stashes.stashWithMessage',
    PaletteCategory.git,
    CupertinoIcons.tray_arrow_down,
  ),
  _ActionSpec(
    'stashes.applyLatest',
    PaletteCategory.git,
    CupertinoIcons.tray_arrow_up,
  ),
  _ActionSpec(
    'stashes.popLatest',
    PaletteCategory.git,
    CupertinoIcons.tray_arrow_up_fill,
  ),
  _ActionSpec('stashes.clearAll', PaletteCategory.git, CupertinoIcons.trash),
  // Forge (panel 4) — gated by the detected forge below.
  _ActionSpec(
    'github.newPr',
    PaletteCategory.forge,
    CupertinoIcons.plus_rectangle,
  ),
  _ActionSpec(
    'github.approve',
    PaletteCategory.forge,
    CupertinoIcons.checkmark_circle,
  ),
  _ActionSpec(
    'github.merge',
    PaletteCategory.forge,
    CupertinoIcons.arrow_merge,
  ),
  _ActionSpec(
    'github.rerun',
    PaletteCategory.forge,
    CupertinoIcons.refresh_thick,
  ),
  _ActionSpec(
    'gitlab.newMr',
    PaletteCategory.forge,
    CupertinoIcons.plus_rectangle,
  ),
  _ActionSpec(
    'gitlab.approve',
    PaletteCategory.forge,
    CupertinoIcons.checkmark_circle,
  ),
  _ActionSpec(
    'gitlab.merge',
    PaletteCategory.forge,
    CupertinoIcons.arrow_merge,
  ),
  _ActionSpec(
    'gitlab.retry',
    PaletteCategory.forge,
    CupertinoIcons.refresh_thick,
  ),
  // Forge-agnostic — offered whichever host this repo uses.
  _ActionSpec(
    'forge.newIssue',
    PaletteCategory.forge,
    CupertinoIcons.exclamationmark_circle,
  ),
  _ActionSpec(
    'forge.cancelAutoMerge',
    PaletteCategory.forge,
    CupertinoIcons.clear_circled,
  ),
  // Worktrees (panel 5).
  _ActionSpec(
    'worktrees.add',
    PaletteCategory.git,
    CupertinoIcons.plus_rectangle_on_rectangle,
  ),
  _ActionSpec(
    'worktrees.open',
    PaletteCategory.git,
    CupertinoIcons.folder_open,
  ),
  _ActionSpec('worktrees.lock', PaletteCategory.git, CupertinoIcons.lock),
  _ActionSpec(
    'worktrees.unlock',
    PaletteCategory.git,
    CupertinoIcons.lock_open,
  ),
  _ActionSpec('worktrees.move', PaletteCategory.git, CupertinoIcons.arrow_swap),
  _ActionSpec('worktrees.repair', PaletteCategory.git, CupertinoIcons.wrench),
  _ActionSpec(
    'worktrees.repairAll',
    PaletteCategory.git,
    CupertinoIcons.wrench_fill,
  ),
  _ActionSpec('worktrees.prune', PaletteCategory.git, CupertinoIcons.scissors),
  _ActionSpec('worktrees.remove', PaletteCategory.git, CupertinoIcons.trash),
  // View/appearance toggles live with the app, not the repo, in the user's
  // mental model — they change what is SHOWN, not the repository.
  _ActionSpec(
    'repository.toggleSplitDiff',
    PaletteCategory.app,
    CupertinoIcons.square_split_2x1,
  ),
  _ActionSpec(
    'repository.toggleIgnoreWhitespace',
    PaletteCategory.app,
    CupertinoIcons.paintbrush,
  ),
  _ActionSpec(
    'repository.toggleExpandContext',
    PaletteCategory.app,
    CupertinoIcons.arrow_up_arrow_down,
  ),
  _ActionSpec('history.zoomIn', PaletteCategory.app, CupertinoIcons.zoom_in),
  _ActionSpec('history.zoomOut', PaletteCategory.app, CupertinoIcons.zoom_out),
  // Reset is an absolute jump back to 100%, not another decrement — so it gets
  // a glyph that reads as "actual size" rather than a third magnifier, which
  // is what made it indistinguishable from Zoom Out in the list.
  _ActionSpec(
    'history.zoomReset',
    PaletteCategory.app,
    CupertinoIcons.fullscreen_exit,
  ),
];

/// A ⌘K quick-action launcher, in the style of VSCode / Linear / Tower's Quick
/// Actions. Fuzzy-filter the full command catalog — navigation, every
/// panel-scoped git/forge action the keymap knows, view toggles, app sheets,
/// and per-branch/worktree targets — arrow to one, Enter to run it.
///
/// Commands are sorted into four categories ([PaletteCategory]) shown as a
/// colored chip per row; typing a `go:` / `git:` / `forge:` / `app:` prefix
/// narrows to that category, VS Code-style.
///
/// Panel-scoped actions run through [PaletteIntent] dispatch
/// ([onDispatchAction]): the shell switches to the owning panel and the
/// panel's own handler — with all its busy/selection guards — executes, the
/// exact code path its keyboard shortcut takes. A selection-dependent action
/// with nothing selected just lands you on its panel.
class CommandPalette extends ConsumerStatefulWidget {
  final String repoPath;
  final void Function(int index) onGoToPanel;
  final VoidCallback onRefresh;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenShortcuts;
  final VoidCallback onOpenConnections;
  final VoidCallback onOpenSavedWorkspaces;
  final ValueChanged<SavedWorkspaceSet> onOpenWorkspaceSet;
  final VoidCallback onCloneRepository;
  final VoidCallback onCreateRepository;
  final VoidCallback onOpenHistoryWindow;
  final VoidCallback onUndo;

  /// Dispatches a panel-scoped keymap action: switch to [panelIndex], then
  /// park the action id as a [PaletteIntent] for that panel to consume.
  final void Function(String actionId, int panelIndex) onDispatchAction;

  /// Runs a guarded checkout of [branch] (dirty-tree prompt + refresh) using the
  /// shell's stable context — the palette is already gone by the time this runs.
  final void Function(String branch) onCheckoutBranch;

  /// Opens a worktree in the Worktrees panel. Takes the shell's context for the
  /// same reason as [onCheckoutBranch] — it may need to prompt for a sandbox
  /// grant on the worktree's folder.
  final void Function(String worktreePath) onOpenWorktree;

  /// Records the semantic entity before its selected action runs.
  final ValueChanged<PaletteEntry>? onOpenEntity;
  final List<GitRef> landedRefs;
  final List<GitWorktree> landedWorktrees;
  final Forge? landedForge;

  const CommandPalette({
    super.key,
    required this.repoPath,
    required this.onGoToPanel,
    required this.onRefresh,
    required this.onOpenSettings,
    required this.onOpenShortcuts,
    required this.onOpenConnections,
    this.onOpenSavedWorkspaces = _noopSavedWorkspaces,
    this.onOpenWorkspaceSet = _noopWorkspaceSet,
    required this.onCloneRepository,
    required this.onCreateRepository,
    required this.onOpenHistoryWindow,
    required this.onUndo,
    required this.onDispatchAction,
    required this.onCheckoutBranch,
    required this.onOpenWorktree,
    this.onOpenEntity,
    this.landedRefs = const [],
    this.landedWorktrees = const [],
    this.landedForge,
  });

  @override
  ConsumerState<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends ConsumerState<CommandPalette> {
  final _query = TextEditingController();
  final _fieldFocus = FocusNode();
  final _scroll = ScrollController();
  int _highlighted = 0;
  PaletteCommand? _selectedEntity;
  Timer? _entityDebounce;
  int _entityGeneration = 0;
  bool _entityLoading = false;
  List<PaletteCommand> _entityResults = const [];
  List<GitRef>? _loadedRefs;
  List<GitWorktree>? _loadedWorktrees;
  Forge? _loadedForge;

  static const _rowHeight = 40.0;

  @override
  void dispose() {
    _entityDebounce?.cancel();
    _query.dispose();
    _fieldFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// The action's primary shortcut under the CURRENT keymap (overrides
  /// included), for the row's hint — or null when unbound.
  String? _shortcutFor(Map<String, List<KeyBinding>> keymap, String id) {
    final bindings = keymap[id];
    if (bindings == null || bindings.isEmpty) return null;
    return bindings.first.label;
  }

  static String _repoBasename(String path) {
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? path : parts.last;
  }

  List<PaletteCommand> _allCommands() {
    // Captured up front so the closures don't touch a torn-down ref/context
    // after the palette pops (the notifiers outlive this widget).
    final fileView = ref.read(fileViewVisibleProvider.notifier);
    final output = ref.read(outputLogProvider.notifier);
    final recovery = ref.read(recoveryVisibleProvider.notifier);
    final keymap = ref.watch(keymapProvider);
    final connNotifier = ref.read(connectionProvider.notifier);
    final currentConn = ref.read(connectionProvider);

    const panels = [
      (0, CupertinoIcons.folder, 'Repository'),
      (1, CupertinoIcons.clock, 'History'),
      (2, CupertinoIcons.arrow_branch, 'Branches'),
      (3, CupertinoIcons.tray_2, 'Stashes'),
      (4, CupertinoIcons.cloud, 'Forge'),
      (5, kWorktreeIcon, 'Worktrees'),
    ];

    final commands = <PaletteCommand>[
      // ---- go: navigation --------------------------------------------------
      for (final (index, icon, name) in panels)
        PaletteCommand(
          icon: icon,
          label: 'Go to $name',
          category: PaletteCategory.go,
          shortcut: _shortcutFor(keymap, 'global.panel${index + 1}'),
          run: () => widget.onGoToPanel(index),
          entry: PanelPaletteEntry(
            id: 'panel:$index',
            primaryLabel: 'Go to $name',
            panelIndex: index,
          ),
        ),
      PaletteCommand(
        icon: CupertinoIcons.macwindow,
        label: 'Open History in New Window',
        category: PaletteCategory.go,
        run: widget.onOpenHistoryWindow,
      ),
    ];

    // ---- git/forge/app: every panel-scoped keymap action -----------------
    // The forge actions are gated by the detected forge, so a GitHub repo
    // isn't offered GitLab merge requests (and vice versa). Unknown / still
    // loading keeps both — better to over-offer than to hide real commands.
    final forge = _loadedForge ?? widget.landedForge;
    bool forgeAllows(String id) {
      if (id.startsWith('github.')) {
        return forge == null || forge == Forge.github || forge == Forge.unknown;
      }
      if (id.startsWith('gitlab.')) {
        return forge == null || forge == Forge.gitlab || forge == Forge.unknown;
      }
      return true;
    }

    for (final spec in _panelActions) {
      if (!forgeAllows(spec.id)) continue;
      final action = kKeymapActionsById[spec.id];
      if (action == null) continue; // an id retired from the keymap
      final panelIndex = spec.panelIndex;
      if (panelIndex == null) continue; // no panel owns it any more
      commands.add(
        PaletteCommand(
          icon: spec.icon,
          label: action.label,
          category: spec.category,
          shortcut: _shortcutFor(keymap, spec.id),
          run: () => widget.onDispatchAction(spec.id, panelIndex),
        ),
      );
    }

    // ---- git: recovery + undo (shell-handled) ----------------------------
    commands.addAll([
      PaletteCommand(
        icon: CupertinoIcons.arrow_uturn_left,
        label: 'Undo Last Git Operation',
        category: PaletteCategory.git,
        shortcut: _shortcutFor(keymap, 'global.undo'),
        run: widget.onUndo,
      ),
      PaletteCommand(
        icon: CupertinoIcons.arrow_counterclockwise_circle,
        label: 'Recovery: Browse Reflog & Snapshots',
        category: PaletteCategory.git,
        run: recovery.toggle,
      ),
      // ---- app: views, sheets, workspace ----------------------------------
      PaletteCommand(
        icon: CupertinoIcons.arrow_clockwise,
        label: 'Refresh',
        category: PaletteCategory.app,
        shortcut: _shortcutFor(keymap, 'global.refresh'),
        run: widget.onRefresh,
      ),
      PaletteCommand(
        icon: CupertinoIcons.sidebar_right,
        label: 'Toggle File View',
        category: PaletteCategory.app,
        shortcut: _shortcutFor(keymap, 'global.toggleFileView'),
        run: fileView.toggle,
      ),
      PaletteCommand(
        icon: CupertinoIcons.square_list,
        label: 'Toggle Output View',
        category: PaletteCategory.app,
        shortcut: _shortcutFor(keymap, 'global.toggleOutput'),
        run: output.toggle,
      ),
      PaletteCommand(
        icon: CupertinoIcons.chart_bar_square,
        label: 'Toggle Dashboard',
        category: PaletteCategory.app,
        shortcut: _shortcutFor(keymap, 'global.toggleDashboard'),
        run: () => ref.read(dashboardVisibleProvider.notifier).toggle(),
      ),
      PaletteCommand(
        icon: CupertinoIcons.arrow_counterclockwise_circle,
        label: 'Toggle Recovery',
        category: PaletteCategory.app,
        shortcut: _shortcutFor(keymap, 'global.toggleRecovery'),
        run: recovery.toggle,
      ),
      PaletteCommand(
        icon: CupertinoIcons.settings,
        label: 'Open Settings',
        category: PaletteCategory.app,
        shortcut: _shortcutFor(keymap, 'global.openSettings'),
        run: widget.onOpenSettings,
      ),
      PaletteCommand(
        icon: CupertinoIcons.command,
        label: 'Keyboard Shortcuts',
        category: PaletteCategory.app,
        shortcut: _shortcutFor(keymap, 'global.showShortcuts'),
        run: widget.onOpenShortcuts,
      ),
      PaletteCommand(
        icon: CupertinoIcons.rectangle_stack_person_crop,
        label: 'Manage Connections',
        category: PaletteCategory.app,
        run: widget.onOpenConnections,
      ),
      PaletteCommand(
        icon: CupertinoIcons.rectangle_stack,
        label: 'Manage Saved Workspaces',
        category: PaletteCategory.app,
        run: widget.onOpenSavedWorkspaces,
      ),
      PaletteCommand(
        icon: CupertinoIcons.cloud_download,
        label: 'Clone Repository',
        category: PaletteCategory.app,
        run: widget.onCloneRepository,
      ),
      PaletteCommand(
        icon: CupertinoIcons.plus_rectangle_on_rectangle,
        label: 'Create Repository',
        category: PaletteCategory.app,
        run: widget.onCreateRepository,
      ),
    ]);

    final tabs = TabsController.current;
    if (tabs != null) {
      for (final tab in tabs.tabs) {
        if (tab.id == tabs.activeId || tab.isBlank) continue;
        final alias = tabs.aliasFor(tab);
        final target = alias ?? _repoBasename(tab.repoPath ?? 'Repository');
        commands.add(
          PaletteCommand(
            icon: CupertinoIcons.rectangle_on_rectangle,
            label: 'Switch to tab $target',
            category: PaletteCategory.go,
            run: () => tabs.activate(tab.id),
            entry: RepositoryPaletteEntry(
              id: 'tab:${tab.id}',
              primaryLabel: 'Switch to tab $target',
              repositoryPath: tab.repoPath ?? '',
              connectionId: tab.connectionId ?? '',
              searchTokens: [?alias, ?tab.repoPath],
              allowedActionIds: const ['repository.open'],
            ),
          ),
        );
      }
    }

    final workspaceSets =
        ref.watch(savedWorkspaceSetsProvider).value ??
        const <SavedWorkspaceSet>[];
    for (final set in workspaceSets) {
      commands.add(
        PaletteCommand(
          icon: CupertinoIcons.rectangle_stack,
          label: 'Open workspace ${set.displayName}',
          category: PaletteCategory.go,
          run: () => widget.onOpenWorkspaceSet(set),
          entry: ActionPaletteEntry(
            id: 'workspace:${set.id}',
            primaryLabel: 'Open workspace ${set.displayName}',
            category: PaletteQueryScope.go,
            searchTokens: [
              for (final repository in set.repositories) ...[
                repository.repoPath,
                if (repository.tabAlias != null) repository.tabAlias!,
              ],
            ],
          ),
        ),
      );
    }

    // ---- dynamic targets: branches (git) and worktrees (go) ---------------
    // Checkout targets: local branches only (checking out a remote-tracking ref
    // detaches HEAD — offer the local ones the guard can switch to cleanly).
    final refs = _loadedRefs ?? widget.landedRefs;
    for (final r in refs.where((r) => r.isLocalBranch)) {
      // A branch checked out in ANOTHER worktree can't be checked out here —
      // git refuses. Offer to go to the worktree that has it instead, so the
      // palette never lists an action that is guaranteed to fail.
      final elsewhere = r.elsewhereWorktreePath;
      commands.add(
        elsewhere == null
            ? PaletteCommand(
                icon: CupertinoIcons.arrow_branch,
                label: 'Checkout ${r.shortName}',
                category: PaletteCategory.git,
                run: () => widget.onCheckoutBranch(r.shortName),
                entry: BranchPaletteEntry(
                  id: 'branch:${r.name}',
                  primaryLabel: 'Checkout ${r.shortName}',
                  refName: r.name,
                  contextLabel: r.subject,
                  searchTokens: [r.shortName, r.name, r.oid],
                  allowedActionIds: const ['branch.checkout'],
                ),
              )
            : PaletteCommand(
                icon: kWorktreeIcon,
                label: 'Switch to worktree for ${r.shortName}',
                category: PaletteCategory.go,
                run: () => widget.onOpenWorktree(elsewhere),
                entry: WorktreePaletteEntry(
                  id: 'worktree:$elsewhere',
                  primaryLabel: 'Switch to worktree for ${r.shortName}',
                  path: elsewhere,
                  contextLabel: elsewhere,
                  allowedActionIds: const ['worktree.open'],
                ),
              ),
      );
    }

    // Worktrees by their own name — how anyone with more than a handful of them
    // actually navigates.
    final worktrees = _loadedWorktrees ?? widget.landedWorktrees;
    for (final wt in worktrees) {
      if (wt.isMain || wt.isPrunable) continue;
      commands.add(
        PaletteCommand(
          icon: kWorktreeIcon,
          label: 'Open worktree ${wt.name}',
          category: PaletteCategory.go,
          run: () => widget.onOpenWorktree(wt.path),
          entry: WorktreePaletteEntry(
            id: 'worktree:${wt.path}',
            primaryLabel: 'Open worktree ${wt.name}',
            path: wt.path,
            contextLabel: wt.branch ?? wt.path,
            searchTokens: [wt.name, wt.path],
            allowedActionIds: const ['worktree.open'],
          ),
        ),
      );
    }

    // ---- go: switch to another saved repository ---------------------------
    // Fuzzy quick-switch, routed exactly like the connection switcher's own
    // tap: a sibling repo on the current connection is a cheap in-session
    // setRepoPath; another connection reconnects (in its tab, under a tab
    // host). Local repos are omitted — they need sandbox-bookmark resolution
    // with a live context the post-dismiss closure doesn't have; pick those
    // from Manage Connections.
    void switchTo(SavedConnection conn, String repo) {
      final tabs = TabsController.current;
      if (tabs == null) {
        if (conn.id == currentConn.connectionId) {
          if (repo != currentConn.repoPath) connNotifier.setRepoPath(repo);
        } else {
          connNotifier.connectToSaved(conn, repoPath: repo);
        }
        return;
      }
      tabs.openOrFocus(
        connectionId: conn.id,
        repoPath: repo,
        savedKind: SavedRepositoryKind.ssh,
        connect: (container) => container
            .read(connectionProvider.notifier)
            .connectToSaved(conn, repoPath: repo),
      );
    }

    final savedConns =
        ref.read(savedConnectionsProvider).value ?? const <SavedConnection>[];
    for (final conn in savedConns) {
      for (final repo in conn.allRepoPaths) {
        // Skip the repo already active on the current connection.
        if (conn.id == currentConn.connectionId &&
            repo == currentConn.repoPath) {
          continue;
        }
        final identity = SavedRepositoryIdentity(
          kind: SavedRepositoryKind.ssh,
          savedId: conn.id,
          repoPath: repo,
        );
        final alias = TabsController.current?.aliasForReference(identity);
        final target = alias ?? _repoBasename(repo);
        commands.add(
          PaletteCommand(
            icon: CupertinoIcons.folder,
            label: 'Switch to $target · ${conn.displayName}',
            category: PaletteCategory.go,
            run: () => switchTo(conn, repo),
            entry: RepositoryPaletteEntry(
              id: 'repository:${conn.id}:$repo',
              primaryLabel: 'Switch to $target · ${conn.displayName}',
              repositoryPath: repo,
              connectionId: conn.id,
              contextLabel: conn.displayName,
              searchTokens: [repo, conn.displayName, ?alias],
              allowedActionIds: const ['repository.open'],
            ),
          ),
        );
      }
    }
    return [...commands, ..._entityResults];
  }

  void _move(int delta, int count) {
    if (count == 0) return;
    setState(() {
      _highlighted = (_highlighted + delta).clamp(0, count - 1);
    });
    // Keep the highlighted row in view as the selection walks off-screen.
    if (_scroll.hasClients) {
      final target = (_highlighted * _rowHeight)
          .clamp(0.0, _scroll.position.maxScrollExtent)
          .toDouble();
      final top = _scroll.offset;
      final bottom = top + _scroll.position.viewportDimension - _rowHeight;
      if (target < top) {
        _scroll.jumpTo(target);
      } else if (target > bottom) {
        _scroll.jumpTo(
          target - _scroll.position.viewportDimension + _rowHeight,
        );
      }
    }
  }

  void _run(PaletteCommand command) {
    if (_selectedEntity == null &&
        parsePaletteQuery(_query.text).isEntity &&
        command.entry.allowedActionIds.isNotEmpty &&
        command.entry.kind != PaletteEntryKind.action &&
        command.entry.kind != PaletteEntryKind.panel) {
      setState(() {
        _selectedEntity = command;
        _highlighted = 0;
      });
      return;
    }
    final selectedEntry = _selectedEntity?.entry;
    Navigator.of(context).pop();
    command.run();
    if (selectedEntry != null) widget.onOpenEntity?.call(selectedEntry);
  }

  List<PaletteCommand> _entityActions(PaletteCommand entity) => [
    for (final actionId in entity.entry.allowedActionIds)
      PaletteCommand(
        icon: actionId == 'branch.checkout'
            ? CupertinoIcons.arrow_branch
            : CupertinoIcons.arrow_right_circle,
        label: switch (actionId) {
          'branch.checkout' ||
          'worktree.open' ||
          'repository.open' => entity.entry.primaryLabel,
          'commit.open' => 'Show commit in History',
          'stash.open' => 'Show stash',
          'file.open' => 'Open changed file',
          _ => actionId,
        },
        category: PaletteCategory.go,
        run: entity.run,
      ),
  ];

  void _onQueryChanged(String raw) {
    setState(() {
      _highlighted = 0;
      _selectedEntity = null;
    });
    _entityDebounce?.cancel();
    final query = parsePaletteQuery(raw);
    if (!query.isEntity && query.scope != PaletteQueryScope.forge) {
      _entityResults = const [];
      _entityLoading = false;
      return;
    }
    final generation = ++_entityGeneration;
    _entityDebounce = Timer(const Duration(milliseconds: 150), () {
      unawaited(_loadEntitySource(query, generation));
    });
  }

  Future<void> _loadEntitySource(PaletteQuery query, int generation) async {
    if (mounted) setState(() => _entityLoading = true);
    final results = <PaletteCommand>[];
    try {
      switch (query.scope) {
        case PaletteQueryScope.branch:
          _loadedRefs = await ref.read(refsProvider(widget.repoPath).future);
        case PaletteQueryScope.worktree:
          _loadedWorktrees = await ref.read(
            gitWorktreesProvider(widget.repoPath).future,
          );
        case PaletteQueryScope.commit:
          final commits = await ref.read(logProvider(widget.repoPath).future);
          for (final commit in commits.take(50)) {
            results.add(
              PaletteCommand(
                icon: CupertinoIcons.clock,
                label: commit.subject,
                category: PaletteCategory.git,
                run: () => widget.onGoToPanel(1),
                entry: CommitPaletteEntry(
                  id: 'commit:${commit.hash}',
                  primaryLabel: commit.subject,
                  oid: commit.hash,
                  contextLabel: commit.shortHash,
                  searchTokens: [commit.hash, commit.authorName],
                  allowedActionIds: const ['commit.open'],
                ),
              ),
            );
          }
        case PaletteQueryScope.stash:
          final stashes = await ref.read(
            stashesProvider(widget.repoPath).future,
          );
          for (final stash in stashes.take(50)) {
            results.add(
              PaletteCommand(
                icon: CupertinoIcons.tray_2,
                label: stash.subject,
                category: PaletteCategory.git,
                run: () => widget.onGoToPanel(3),
                entry: StashPaletteEntry(
                  id: 'stash:${stash.oid}',
                  primaryLabel: stash.subject,
                  oid: stash.oid,
                  contextLabel: stash.ref,
                  searchTokens: [stash.oid, stash.branch],
                  allowedActionIds: const ['stash.open'],
                ),
              ),
            );
          }
        case PaletteQueryScope.file:
          final status = await ref.read(statusProvider(widget.repoPath).future);
          final paths = <String>{
            ...status.staged.map((item) => item.path),
            ...status.unstaged.map((item) => item.path),
            ...status.untracked.map((item) => item.path),
            ...status.conflicted.map((item) => item.path),
          };
          for (final path in paths.take(50)) {
            results.add(
              PaletteCommand(
                icon: CupertinoIcons.doc,
                label: path,
                category: PaletteCategory.go,
                run: () => widget.onGoToPanel(0),
                entry: FilePaletteEntry.changed(
                  id: 'changed-file:$path',
                  primaryLabel: path,
                  path: path,
                  allowedActionIds: const ['file.open'],
                ),
              ),
            );
          }
        case PaletteQueryScope.issue ||
            PaletteQueryScope.request ||
            PaletteQueryScope.ci:
        // Forge adapters contribute landed values in Phase 8. Keeping these
        // scopes empty is preferable to starting every forge provider.
        case PaletteQueryScope.forge:
          _loadedForge = await ref.read(forgeProvider(widget.repoPath).future);
        case PaletteQueryScope.all ||
            PaletteQueryScope.go ||
            PaletteQueryScope.git ||
            PaletteQueryScope.app:
          break;
      }
    } catch (_) {
      // One failed source leaves the rest of the palette available.
    }
    if (!mounted || generation != _entityGeneration) return;
    setState(() {
      _entityResults = results;
      _entityLoading = false;
      _highlighted = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final query = parsePaletteQuery(_query.text);
    final allCommands = _selectedEntity == null
        ? _allCommands()
        : _entityActions(_selectedEntity!);
    final ranked = _selectedEntity == null
        ? rankPaletteEntries(allCommands.map((command) => command.entry), query)
        : allCommands.map((command) => command.entry).toList();
    final byEntry = {for (final command in allCommands) command.entry: command};
    final commands = [for (final entry in ranked) byEntry[entry]!];
    if (_highlighted >= commands.length) {
      _highlighted = commands.isEmpty ? 0 : commands.length - 1;
    }

    return CallbackShortcuts(
      // These win over the text field's default caret shortcuts because this
      // CallbackShortcuts sits closer to the focused field than the app-wide
      // DefaultTextEditingShortcuts (the same mechanism Flutter's Autocomplete
      // uses to drive arrow-key option navigation from inside a text field).
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _move(1, commands.length),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _move(-1, commands.length),
        const SingleActivator(LogicalKeyboardKey.enter): () {
          if (commands.isNotEmpty) _run(commands[_highlighted]);
        },
        // No Escape here: dismissal comes from the EscapeDismissible wrapper
        // at the call site (registry-based, focus-independent). These three
        // are legitimately focus-scoped — they only make sense while typing
        // in the (autofocused) query field.
      },
      child: SizedSheet(
        width: kSheetWidth,
        height: 420,
        child: SizedBox(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MacosTextField(
                  controller: _query,
                  focusNode: _fieldFocus,
                  autofocus: true,
                  placeholder: 'Go to or do — try branch:, commit:, file:…',
                  placeholderStyle: kAppPlaceholderStyle,
                  prefix: const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: MacosIcon(CupertinoIcons.search, size: 14),
                  ),
                  decoration: kAppTextFieldDecoration,
                  focusedDecoration: kAppTextFieldFocusedDecoration,
                  onChanged: _onQueryChanged,
                ),
                FieldHint(
                  // issue:/request:/ci: parse but contribute nothing yet
                  // (Phase 8) — advertising them was a taught no-op (0009 M7).
                  _selectedEntity == null
                      ? 'Prefix with go:, git:, forge:, app:, branch:, '
                            'commit:, file:, stash:, or worktree:. '
                            '↑/↓ to highlight, Return to open.'
                      : 'Choose an action for '
                            '${_selectedEntity!.entry.primaryLabel}.',
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: commands.isEmpty && _entityLoading
                      ? const Center(child: ProgressCircle(radius: 10))
                      : commands.isEmpty
                      ? Center(
                          child: Text(
                            'No matching commands',
                            style: typography.body.copyWith(
                              color: MacosColors.systemGrayColor,
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          itemExtent: _rowHeight,
                          itemCount: commands.length,
                          itemBuilder: (context, i) => _row(
                            context,
                            commands[i],
                            i == _highlighted,
                            position: i + 1,
                            count: commands.length,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    PaletteCommand command,
    bool highlighted, {
    required int position,
    required int count,
  }) {
    final typography = MacosTheme.of(context).typography;
    // Tappable carries no semantics of its own, so without this a row reads as
    // three unrelated fragments — name, shortcut, and a naked category word.
    // `selected` mirrors the arrow-key cursor, matching NavRail and TabStrip.
    return Semantics(
      button: true,
      selected: highlighted,
      label: paletteRowSemanticsLabel(
        label: command.label,
        categoryPrefix: command.category.prefix,
        shortcut: command.shortcut,
        position: position,
        count: count,
      ),
      child: Tappable(
        onTap: () => _run(command),
        // The label above already speaks every piece below; without this the
        // screen reader repeats the name, the shortcut and the chip word.
        child: ExcludeSemantics(
          child: Container(
            height: _rowHeight,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: highlighted
                  ? MacosColors.systemBlueColor.withValues(alpha: 0.22)
                  : const Color(0x00000000),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                MacosIcon(command.icon, size: 15),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    command.label,
                    style: typography.body,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (command.shortcut != null) ...[
                  Text(
                    command.shortcut!,
                    style: typography.caption1.copyWith(
                      color: MacosColors.systemGrayColor,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                _categoryChip(command.category),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The row's category, as the same 15%-alpha pill the forge badges use —
  /// color-stable per category so the list scans by hue.
  Widget _categoryChip(PaletteCategory category) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: category.color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        category.prefix,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: category.color,
        ),
      ),
    );
  }
}
