import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/forge/forge.dart';
import '../../core/output/output_log.dart';
import '../../core/providers/app_providers.dart';
import '../../core/settings/keymap.dart';
import '../../core/storage/saved_connection.dart';
import '../tabs/tabs_controller.dart';
import '../worktrees/worktree_tabs.dart';
import 'field_styles.dart';
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
class _PaletteCommand {
  final IconData icon;
  final String label;
  final PaletteCategory category;

  /// The action's current keyboard shortcut, when it has one — shown as a
  /// right-aligned hint so the palette doubles as shortcut discovery.
  final String? shortcut;
  final VoidCallback run;
  const _PaletteCommand({
    required this.icon,
    required this.label,
    required this.category,
    required this.run,
    this.shortcut,
  });
}

/// Palette metadata for a keymap-registered, panel-scoped action: where it
/// lives (so the palette can switch there) and how it reads in the list. The
/// label comes from [kKeymapActionsById] — one source of truth with the
/// Keyboard Shortcuts sheet.
class _ActionSpec {
  final String id;
  final PaletteCategory category;
  final int panelIndex;
  final IconData icon;
  const _ActionSpec(this.id, this.category, this.panelIndex, this.icon);
}

/// Every panel-scoped keymap action the palette offers, in display order.
///
/// Deliberate exclusions: `global.*` (the shell handles those directly — the
/// panel switches are the palette's own "Go to" rows), `commit.*` (only
/// meaningful inside the commit sheet) and `viewer.*` (scoped to a viewer
/// window the palette can't address).
const List<_ActionSpec> _panelActions = [
  // Repository (panel 0) — sync + staging + commit.
  _ActionSpec('repository.fetch', PaletteCategory.git, 0, CupertinoIcons.cloud_download),
  _ActionSpec('repository.pull', PaletteCategory.git, 0, CupertinoIcons.arrow_down_circle),
  _ActionSpec('repository.push', PaletteCategory.git, 0, CupertinoIcons.arrow_up_circle),
  _ActionSpec('repository.sync', PaletteCategory.git, 0, CupertinoIcons.arrow_2_circlepath),
  _ActionSpec('repository.forcePush', PaletteCategory.git, 0, CupertinoIcons.arrow_up_circle_fill),
  _ActionSpec('repository.stageAll', PaletteCategory.git, 0, CupertinoIcons.tray_arrow_down),
  _ActionSpec('repository.toggleStage', PaletteCategory.git, 0, CupertinoIcons.tray_arrow_down_fill),
  _ActionSpec('repository.discard', PaletteCategory.git, 0, CupertinoIcons.trash),
  _ActionSpec('repository.focusCommit', PaletteCategory.git, 0, CupertinoIcons.checkmark_seal),
  _ActionSpec('repository.stash', PaletteCategory.git, 0, CupertinoIcons.tray_2),
  // History (panel 1) — commit-level operations.
  _ActionSpec('history.filter', PaletteCategory.git, 1, CupertinoIcons.search),
  _ActionSpec('history.copySha', PaletteCategory.git, 1, CupertinoIcons.doc_on_clipboard),
  _ActionSpec('history.checkout', PaletteCategory.git, 1, CupertinoIcons.arrow_branch),
  _ActionSpec('history.branchFrom', PaletteCategory.git, 1, CupertinoIcons.arrow_branch),
  _ActionSpec('history.cherryPick', PaletteCategory.git, 1, CupertinoIcons.arrow_merge),
  _ActionSpec('history.rebaseFrom', PaletteCategory.git, 1, CupertinoIcons.arrow_swap),
  _ActionSpec('history.amend', PaletteCategory.git, 1, CupertinoIcons.pencil_circle),
  // Branches (panel 2).
  _ActionSpec('branches.newBranch', PaletteCategory.git, 2, CupertinoIcons.plus_circle),
  _ActionSpec('branches.createTag', PaletteCategory.git, 2, CupertinoIcons.tag),
  _ActionSpec('branches.merge', PaletteCategory.git, 2, CupertinoIcons.arrow_merge),
  _ActionSpec('branches.delete', PaletteCategory.git, 2, CupertinoIcons.trash),
  _ActionSpec('branches.publish', PaletteCategory.git, 2, CupertinoIcons.cloud_upload),
  _ActionSpec('branches.createRequest', PaletteCategory.forge, 2, CupertinoIcons.plus_rectangle_on_rectangle),
  _ActionSpec('branches.openCi', PaletteCategory.forge, 2, CupertinoIcons.gauge),
  _ActionSpec('branches.compare', PaletteCategory.git, 2, CupertinoIcons.doc_text),
  // Stashes (panel 3).
  _ActionSpec('stashes.apply', PaletteCategory.git, 3, CupertinoIcons.tray_arrow_up),
  _ActionSpec('stashes.pop', PaletteCategory.git, 3, CupertinoIcons.tray_arrow_up_fill),
  _ActionSpec('stashes.drop', PaletteCategory.git, 3, CupertinoIcons.trash),
  // Forge (panel 4) — gated by the detected forge below.
  _ActionSpec('github.newPr', PaletteCategory.forge, 4, CupertinoIcons.plus_rectangle),
  _ActionSpec('github.approve', PaletteCategory.forge, 4, CupertinoIcons.checkmark_circle),
  _ActionSpec('github.merge', PaletteCategory.forge, 4, CupertinoIcons.arrow_merge),
  _ActionSpec('github.rerun', PaletteCategory.forge, 4, CupertinoIcons.refresh_thick),
  _ActionSpec('gitlab.newMr', PaletteCategory.forge, 4, CupertinoIcons.plus_rectangle),
  _ActionSpec('gitlab.approve', PaletteCategory.forge, 4, CupertinoIcons.checkmark_circle),
  _ActionSpec('gitlab.merge', PaletteCategory.forge, 4, CupertinoIcons.arrow_merge),
  _ActionSpec('gitlab.retry', PaletteCategory.forge, 4, CupertinoIcons.refresh_thick),
  // View/appearance toggles live with the app, not the repo, in the user's
  // mental model — they change what is SHOWN, not the repository.
  _ActionSpec('repository.toggleSplitDiff', PaletteCategory.app, 0, CupertinoIcons.square_split_2x1),
  _ActionSpec('repository.toggleIgnoreWhitespace', PaletteCategory.app, 0, CupertinoIcons.paintbrush),
  _ActionSpec('repository.toggleExpandContext', PaletteCategory.app, 0, CupertinoIcons.arrow_up_arrow_down),
  _ActionSpec('history.zoomIn', PaletteCategory.app, 1, CupertinoIcons.zoom_in),
  _ActionSpec('history.zoomOut', PaletteCategory.app, 1, CupertinoIcons.zoom_out),
  _ActionSpec('history.zoomReset', PaletteCategory.app, 1, CupertinoIcons.zoom_out),
  // zoomReset uses a distinct glyph from zoomOut for discoverability.
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

  const CommandPalette({
    super.key,
    required this.repoPath,
    required this.onGoToPanel,
    required this.onRefresh,
    required this.onOpenSettings,
    required this.onOpenShortcuts,
    required this.onOpenConnections,
    required this.onCloneRepository,
    required this.onCreateRepository,
    required this.onOpenHistoryWindow,
    required this.onUndo,
    required this.onDispatchAction,
    required this.onCheckoutBranch,
    required this.onOpenWorktree,
  });

  @override
  ConsumerState<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends ConsumerState<CommandPalette> {
  final _query = TextEditingController();
  final _fieldFocus = FocusNode();
  final _scroll = ScrollController();
  int _highlighted = 0;

  static const _rowHeight = 40.0;

  @override
  void dispose() {
    _query.dispose();
    _fieldFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Case-insensitive subsequence match: every character of [q] appears in [s]
  /// in order (so "grst" matches "Go to Repository Status"). Empty query
  /// matches everything.
  static bool _matches(String q, String s) {
    if (q.isEmpty) return true;
    final query = q.toLowerCase();
    final target = s.toLowerCase();
    var i = 0;
    for (var j = 0; j < target.length && i < query.length; j++) {
      if (target[j] == query[i]) i++;
    }
    return i == query.length;
  }

  /// Splits the raw query into an optional category restriction and the text
  /// to fuzzy-match: `git: pu` → (git, "pu"). A prefix that names no category
  /// is treated as plain text (so searching for a literal `origin: fix` still
  /// works).
  static (PaletteCategory?, String) parseQuery(String raw) {
    final colon = raw.indexOf(':');
    if (colon > 0) {
      final category = PaletteCategory.byPrefix(raw.substring(0, colon));
      if (category != null) {
        return (category, raw.substring(colon + 1).trim());
      }
    }
    return (null, raw.trim());
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

  List<_PaletteCommand> _allCommands() {
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

    final commands = <_PaletteCommand>[
      // ---- go: navigation --------------------------------------------------
      for (final (index, icon, name) in panels)
        _PaletteCommand(
          icon: icon,
          label: 'Go to $name',
          category: PaletteCategory.go,
          shortcut: _shortcutFor(keymap, 'global.panel${index + 1}'),
          run: () => widget.onGoToPanel(index),
        ),
      _PaletteCommand(
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
    final forge = ref.watch(forgeProvider(widget.repoPath)).value;
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
      commands.add(
        _PaletteCommand(
          icon: spec.icon,
          label: action.label,
          category: spec.category,
          shortcut: _shortcutFor(keymap, spec.id),
          run: () => widget.onDispatchAction(spec.id, spec.panelIndex),
        ),
      );
    }

    // ---- git: recovery + undo (shell-handled) ----------------------------
    commands.addAll([
      _PaletteCommand(
        icon: CupertinoIcons.arrow_uturn_left,
        label: 'Undo Last Git Operation',
        category: PaletteCategory.git,
        shortcut: _shortcutFor(keymap, 'global.undo'),
        run: widget.onUndo,
      ),
      _PaletteCommand(
        icon: CupertinoIcons.arrow_counterclockwise_circle,
        label: 'Recovery: Browse Reflog & Snapshots',
        category: PaletteCategory.git,
        run: recovery.toggle,
      ),
      // ---- app: views, sheets, workspace ----------------------------------
      _PaletteCommand(
        icon: CupertinoIcons.arrow_clockwise,
        label: 'Refresh',
        category: PaletteCategory.app,
        shortcut: _shortcutFor(keymap, 'global.refresh'),
        run: widget.onRefresh,
      ),
      _PaletteCommand(
        icon: CupertinoIcons.sidebar_right,
        label: 'Toggle File View',
        category: PaletteCategory.app,
        shortcut: _shortcutFor(keymap, 'global.toggleFileView'),
        run: fileView.toggle,
      ),
      _PaletteCommand(
        icon: CupertinoIcons.square_list,
        label: 'Toggle Output View',
        category: PaletteCategory.app,
        shortcut: _shortcutFor(keymap, 'global.toggleOutput'),
        run: output.toggle,
      ),
      _PaletteCommand(
        icon: CupertinoIcons.chart_bar_square,
        label: 'Toggle Dashboard',
        category: PaletteCategory.app,
        shortcut: _shortcutFor(keymap, 'global.toggleDashboard'),
        run: () =>
            ref.read(dashboardVisibleProvider.notifier).toggle(),
      ),
      _PaletteCommand(
        icon: CupertinoIcons.arrow_counterclockwise_circle,
        label: 'Toggle Recovery',
        category: PaletteCategory.app,
        shortcut: _shortcutFor(keymap, 'global.toggleRecovery'),
        run: recovery.toggle,
      ),
      _PaletteCommand(
        icon: CupertinoIcons.settings,
        label: 'Open Settings',
        category: PaletteCategory.app,
        shortcut: _shortcutFor(keymap, 'global.openSettings'),
        run: widget.onOpenSettings,
      ),
      _PaletteCommand(
        icon: CupertinoIcons.command,
        label: 'Keyboard Shortcuts',
        category: PaletteCategory.app,
        shortcut: _shortcutFor(keymap, 'global.showShortcuts'),
        run: widget.onOpenShortcuts,
      ),
      _PaletteCommand(
        icon: CupertinoIcons.rectangle_stack_person_crop,
        label: 'Manage Connections',
        category: PaletteCategory.app,
        run: widget.onOpenConnections,
      ),
      _PaletteCommand(
        icon: CupertinoIcons.cloud_download,
        label: 'Clone Repository',
        category: PaletteCategory.app,
        run: widget.onCloneRepository,
      ),
      _PaletteCommand(
        icon: CupertinoIcons.plus_rectangle_on_rectangle,
        label: 'Create Repository',
        category: PaletteCategory.app,
        run: widget.onCreateRepository,
      ),
    ]);

    // ---- dynamic targets: branches (git) and worktrees (go) ---------------
    // Checkout targets: local branches only (checking out a remote-tracking ref
    // detaches HEAD — offer the local ones the guard can switch to cleanly).
    final refs = ref.watch(refsProvider(widget.repoPath)).value ?? const [];
    for (final r in refs.where((r) => r.isLocalBranch)) {
      // A branch checked out in ANOTHER worktree can't be checked out here —
      // git refuses. Offer to go to the worktree that has it instead, so the
      // palette never lists an action that is guaranteed to fail.
      final elsewhere = r.elsewhereWorktreePath;
      commands.add(
        elsewhere == null
            ? _PaletteCommand(
                icon: CupertinoIcons.arrow_branch,
                label: 'Checkout ${r.shortName}',
                category: PaletteCategory.git,
                run: () => widget.onCheckoutBranch(r.shortName),
              )
            : _PaletteCommand(
                icon: kWorktreeIcon,
                label: 'Switch to worktree for ${r.shortName}',
                category: PaletteCategory.go,
                run: () => widget.onOpenWorktree(elsewhere),
              ),
      );
    }

    // Worktrees by their own name — how anyone with more than a handful of them
    // actually navigates.
    final worktrees =
        ref.watch(gitWorktreesProvider(widget.repoPath)).value ?? const [];
    for (final wt in worktrees) {
      if (wt.isMain || wt.isPrunable) continue;
      commands.add(
        _PaletteCommand(
          icon: kWorktreeIcon,
          label: 'Open worktree ${wt.name}',
          category: PaletteCategory.go,
          run: () => widget.onOpenWorktree(wt.path),
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
        connect: (container) => container
            .read(connectionProvider.notifier)
            .connectToSaved(conn, repoPath: repo),
      );
    }

    final savedConns =
        ref.watch(savedConnectionsProvider).value ?? const <SavedConnection>[];
    for (final conn in savedConns) {
      for (final repo in conn.allRepoPaths) {
        // Skip the repo already active on the current connection.
        if (conn.id == currentConn.connectionId &&
            repo == currentConn.repoPath) {
          continue;
        }
        commands.add(
          _PaletteCommand(
            icon: CupertinoIcons.folder,
            label: 'Switch to ${_repoBasename(repo)} · ${conn.displayName}',
            category: PaletteCategory.go,
            run: () => switchTo(conn, repo),
          ),
        );
      }
    }
    return commands;
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
        _scroll.jumpTo(target - _scroll.position.viewportDimension + _rowHeight);
      }
    }
  }

  void _run(_PaletteCommand command) {
    Navigator.of(context).pop();
    command.run();
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final (category, text) = parseQuery(_query.text);
    final commands = _allCommands()
        .where(
          (c) =>
              (category == null || c.category == category) &&
              // Match against the label alone AND the prefixed form, so
              // typing "git fetch" (no colon) finds `git: Fetch` too.
              (_matches(text, c.label) ||
                  _matches(text, '${c.category.prefix} ${c.label}')),
        )
        .toList();
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
                  placeholder: 'Type a command — or go: git: forge: app:…',
                  placeholderStyle: kAppPlaceholderStyle,
                  prefix: const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: MacosIcon(CupertinoIcons.search, size: 14),
                  ),
                  decoration: kAppTextFieldDecoration,
                  focusedDecoration: kAppTextFieldFocusedDecoration,
                  onChanged: (_) => setState(() => _highlighted = 0),
                ),
                const FieldHint(
                  'Search every command and branch — prefix with go: git: '
                  'forge: or app: to narrow a category. ↑/↓ to highlight, '
                  'Return to run, Esc to close.',
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: commands.isEmpty
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
                          itemBuilder: (context, i) =>
                              _row(context, commands[i], i == _highlighted),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, _PaletteCommand command, bool highlighted) {
    final typography = MacosTheme.of(context).typography;
    return Tappable(
      onTap: () => _run(command),
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
