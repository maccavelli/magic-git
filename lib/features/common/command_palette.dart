import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';
import '../../core/output/output_log.dart';
import '../../core/providers/app_providers.dart';
import '../worktrees/worktree_tabs.dart';
import 'field_styles.dart';
import 'sized_sheet.dart';

/// One runnable entry in the [CommandPalette]. [run] is invoked *after* the
/// palette has closed, so it must not depend on the palette's own context — the
/// closures here call back into the app shell (whose context is stable) or into
/// notifiers captured up front.
class _PaletteCommand {
  final IconData icon;
  final String label;

  /// A short right-aligned hint — the section ("Go to", "Branch") or a value.
  final String? hint;
  final VoidCallback run;
  const _PaletteCommand({
    required this.icon,
    required this.label,
    required this.run,
    this.hint,
  });
}

/// A ⌘K quick-action launcher, in the style of VSCode / Linear / Tower's Quick
/// Actions — the top "please add this" request across git GUIs. Fuzzy-filter a
/// flat list of navigation targets and quick actions, arrow to one, Enter to
/// run it. Everything it offers is globally dispatchable (panel switches, view
/// toggles, refresh, opening the settings/shortcuts/connections sheets, and
/// checking out a local branch behind the usual dirty-tree guard), so it never
/// lists an action it can't actually perform from here.
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

  List<_PaletteCommand> _allCommands() {
    // Captured up front so the closures don't touch a torn-down ref/context
    // after the palette pops (the notifiers outlive this widget).
    final fileView = ref.read(fileViewVisibleProvider.notifier);
    final output = ref.read(outputLogProvider.notifier);
    final recovery = ref.read(recoveryVisibleProvider.notifier);

    const panels = [
      (0, CupertinoIcons.folder, 'Repository'),
      (1, CupertinoIcons.clock, 'History'),
      (2, CupertinoIcons.arrow_branch, 'Branches'),
      (3, CupertinoIcons.tray_2, 'Stashes'),
      (4, CupertinoIcons.cloud, 'Forge'),
      (5, CupertinoIcons.cube_box, 'Project'),
      (6, kWorktreeIcon, 'Worktrees'),
    ];

    final commands = <_PaletteCommand>[
      for (final (index, icon, name) in panels)
        _PaletteCommand(
          icon: icon,
          label: 'Go to $name',
          hint: 'Go to',
          run: () => widget.onGoToPanel(index),
        ),
      _PaletteCommand(
        icon: CupertinoIcons.arrow_clockwise,
        label: 'Refresh',
        hint: 'Action',
        run: widget.onRefresh,
      ),
      _PaletteCommand(
        icon: CupertinoIcons.sidebar_right,
        label: 'Toggle File View',
        hint: 'View',
        run: fileView.toggle,
      ),
      _PaletteCommand(
        icon: CupertinoIcons.square_list,
        label: 'Toggle Output View',
        hint: 'View',
        run: output.toggle,
      ),
      _PaletteCommand(
        icon: CupertinoIcons.arrow_counterclockwise_circle,
        label: 'Recovery: Browse Reflog & Snapshots',
        hint: 'Open',
        run: recovery.toggle,
      ),
      _PaletteCommand(
        icon: CupertinoIcons.macwindow,
        label: 'Open History in New Window',
        hint: 'Open',
        run: widget.onOpenHistoryWindow,
      ),
      _PaletteCommand(
        icon: CupertinoIcons.settings,
        label: 'Open Settings',
        hint: 'Open',
        run: widget.onOpenSettings,
      ),
      _PaletteCommand(
        icon: CupertinoIcons.command,
        label: 'Keyboard Shortcuts',
        hint: 'Open',
        run: widget.onOpenShortcuts,
      ),
      _PaletteCommand(
        icon: CupertinoIcons.rectangle_stack_person_crop,
        label: 'Manage Connections',
        hint: 'Open',
        run: widget.onOpenConnections,
      ),
      _PaletteCommand(
        icon: CupertinoIcons.cloud_download,
        label: 'Clone Repository',
        hint: 'Open',
        run: widget.onCloneRepository,
      ),
      _PaletteCommand(
        icon: CupertinoIcons.plus_rectangle_on_rectangle,
        label: 'Create Repository',
        hint: 'Open',
        run: widget.onCreateRepository,
      ),
    ];

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
                hint: 'Branch',
                run: () => widget.onCheckoutBranch(r.shortName),
              )
            : _PaletteCommand(
                icon: kWorktreeIcon,
                label: 'Switch to worktree for ${r.shortName}',
                hint: 'Worktree',
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
          hint: 'Worktree',
          run: () => widget.onOpenWorktree(wt.path),
        ),
      );
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
    final commands = _allCommands()
        .where((c) => _matches(_query.text.trim(), c.label))
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
                  placeholder: 'Type a command or branch…',
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
                  'Search every app command and branch — ↑/↓ to highlight, '
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
    return GestureDetector(
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
            if (command.hint != null)
              Text(
                command.hint!,
                style: typography.caption1.copyWith(
                  color: MacosColors.systemGrayColor,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
