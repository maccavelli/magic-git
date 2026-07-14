import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../core/git/git_service.dart';
import '../../core/local/security_scoped_bookmark.dart';
import '../../core/providers/app_providers.dart';
import '../common/actions.dart';
import '../common/field_styles.dart';
import '../common/labeled_text_field.dart';
import '../common/sized_sheet.dart';
import 'worktree_access.dart';
import 'worktree_tabs.dart';

/// How the new worktree's HEAD is chosen.
enum _Basis {
  /// Create a new branch (the common case — a worktree per piece of work).
  newBranch,

  /// Check out a branch that already exists and isn't checked out elsewhere.
  existingBranch,

  /// Detached HEAD at some revision — for reviewing or testing history without
  /// claiming a branch name.
  detached,
}

/// Creates a worktree.
///
/// Two things here exist in no other desktop Git GUI, and they are what make
/// worktrees actually usable rather than merely supported:
///
///  * **Copy ignored files.** `git worktree add` checks out *tracked* files
///    only. So a fresh worktree has no `.env`, and the project fails on first
///    run with a baffling error. This is the single most common complaint about
///    worktrees in practice; VS Code solved it (`git.worktreeIncludeFiles`) and
///    Tower, Fork and GitKraken have not.
///  * **A post-create command**, e.g. `pnpm install`, so the worktree is ready
///    to work in instead of ready to configure.
class AddWorktreeSheet extends ConsumerStatefulWidget {
  final String repoPath;

  /// Pre-selects a starting point — set when this is opened from "Checkout in
  /// New Worktree…" on a branch, or "Branch from here…" on a commit.
  final String? initialCommitish;
  final String? initialBranchName;

  const AddWorktreeSheet({
    super.key,
    required this.repoPath,
    this.initialCommitish,
    this.initialBranchName,
  });

  @override
  ConsumerState<AddWorktreeSheet> createState() => _AddWorktreeSheetState();
}

class _AddWorktreeSheetState extends ConsumerState<AddWorktreeSheet> {
  final _branch = TextEditingController();
  final _location = TextEditingController();
  final _copyGlobs = TextEditingController(text: '.env*');
  final _postCreate = TextEditingController();

  _Basis _basis = _Basis.newBranch;
  String? _existingBranch;
  String? _commitish;
  bool _copyIgnored = true;
  bool _runPostCreate = false;
  bool _openAfter = true;
  bool _submitting = false;

  /// True once the user has edited the location themselves, after which we stop
  /// overwriting it as they type a branch name.
  bool _locationEdited = false;

  /// The folder the user granted through the picker, if any. Under the sandbox
  /// this is what makes the destination writable at all — `git worktree add`
  /// creates a directory, and the app may only write where it has been let in.
  String? _grantedParent;

  @override
  void initState() {
    super.initState();
    _commitish = widget.initialCommitish;
    if (widget.initialBranchName != null) {
      _branch.text = widget.initialBranchName!;
    }
    if (widget.initialCommitish != null && widget.initialBranchName == null) {
      _basis = _Basis.existingBranch;
      _existingBranch = widget.initialCommitish;
    }
    _syncLocation();
  }

  @override
  void dispose() {
    _branch.dispose();
    _location.dispose();
    _copyGlobs.dispose();
    _postCreate.dispose();
    super.dispose();
  }

  /// The conventional default: a sibling of the repo named after the branch.
  ///
  ///   ~/code/myapp          <- main worktree
  ///   ~/code/myapp-feat-auth
  ///
  /// A sibling, never a subdirectory: a worktree nested inside the main repo
  /// pollutes its `git status` with a second checkout's files and confuses every
  /// tool that walks up looking for a repo root.
  void _syncLocation() {
    if (_locationEdited) return;
    final parent = _defaultParent();
    final slug = _slug(
      switch (_basis) {
        _Basis.newBranch => _branch.text,
        _Basis.existingBranch => _existingBranch ?? '',
        _Basis.detached => _commitish ?? 'detached',
      },
    );
    final repoName = widget.repoPath.split('/').last;
    _location.text = slug.isEmpty ? '' : '$parent/$repoName-$slug';
  }

  String _defaultParent() {
    if (_grantedParent != null) return _grantedParent!;
    final parts = widget.repoPath.split('/')..removeLast();
    return parts.join('/');
  }

  /// `feature/auth` -> `feature-auth`. Slashes would create nested directories,
  /// and a branch name is otherwise a fine folder name.
  static String _slug(String branch) => branch
      .trim()
      .replaceAll(RegExp(r'[/\s]+'), '-')
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  bool get _valid {
    if (_location.text.trim().isEmpty) return false;
    return switch (_basis) {
      _Basis.newBranch => _branch.text.trim().isNotEmpty,
      _Basis.existingBranch => _existingBranch != null,
      _Basis.detached => (_commitish ?? '').trim().isNotEmpty,
    };
  }

  /// The destination must not be inside the main worktree. git will happily do
  /// it and leave you with a nested checkout whose files show up as untracked
  /// noise in the parent's status.
  String? get _locationProblem {
    final path = _location.text.trim();
    if (path.isEmpty) return null;
    final repo = widget.repoPath;
    if (path == repo || path.startsWith('$repo/')) {
      return 'Choose a folder outside the repository — a worktree inside it '
          "would show up as untracked files in the repository's own status.";
    }
    if (!path.startsWith('/')) return 'Choose an absolute path.';
    return null;
  }

  Future<void> _pickLocation() async {
    // Under the sandbox the picker is not a convenience, it is the only way to
    // gain write access to the destination. The user picks the PARENT folder;
    // `git worktree add` then creates the worktree directory inside it, under
    // the grant we just received.
    final picked = await getDirectoryPath(
      confirmButtonText: 'Choose',
      initialDirectory: _defaultParent(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _grantedParent = picked;
      _locationEdited = false;
      _syncLocation();
    });
  }

  Future<void> _submit() async {
    if (!_valid || _submitting) return;
    final problem = _locationProblem;
    if (problem != null) {
      await showErrorDialog(context, problem);
      return;
    }
    setState(() => _submitting = true);

    final git = ref.read(gitServiceProvider);
    final path = _location.text.trim();
    final repoPath = widget.repoPath;

    final ok = await runAction(context, () async {
      await git.addWorktree(
        repoPath,
        path: path,
        newBranch: _basis == _Basis.newBranch ? _branch.text.trim() : null,
        commitish: switch (_basis) {
          _Basis.newBranch => _commitish,
          _Basis.existingBranch => _existingBranch,
          _Basis.detached => _commitish,
        },
        detach: _basis == _Basis.detached,
      );

      // Only tracked files were checked out. Bring across the ignored ones the
      // project actually needs to run — without this the new worktree is a
      // checkout you still have to hand-configure before it will start.
      if (_copyIgnored && _copyGlobs.text.trim().isNotEmpty) {
        await git.copyIgnoredFiles(
          from: repoPath,
          to: path,
          globs: _copyGlobs.text
              .split(',')
              .map((g) => g.trim())
              .where((g) => g.isNotEmpty)
              .toList(),
        );
      }

      if (_runPostCreate && _postCreate.text.trim().isNotEmpty) {
        await git.runInWorktree(path, _postCreate.text.trim());
      }
    });
    if (!ok || !mounted) {
      setState(() => _submitting = false);
      return;
    }

    // Remember the grant, so opening this worktree later never prompts. The
    // parent-folder grant covers it; a bookmark on the worktree itself is what
    // survives a restart.
    if (ref.read(connectionProvider).isLocal) {
      final bookmark = await SecurityScopedBookmark.create(path);
      if (bookmark != null) {
        await ref.read(worktreeAccessProvider).remember(path, bookmark);
      }
    }
    if (!mounted) return;

    if (_openAfter) ref.read(worktreeTabsProvider.notifier).open(path);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final typography = MacosTheme.of(context).typography;
    final refs = ref.watch(refsProvider(widget.repoPath)).value ?? const [];
    final locals = refs.where((r) => r.isLocalBranch).toList();
    final problem = _locationProblem;

    return SizedSheet(
      width: 520,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Add Worktree', style: typography.title2),
            const SheetDescription(
              'A worktree is another checkout of this repository in its own '
              'folder, with its own branch — so you can work on two things at '
              'once without stashing.',
            ),
            const SizedBox(height: 16),

            _basisPicker(context, locals),
            const SizedBox(height: 12),

            if (_basis == _Basis.newBranch)
              LabeledTextField(
                label: 'New branch name',
                controller: _branch,
                placeholder: 'feature/auth',
                onChanged: () => setState(_syncLocation),
              ),
            if (_basis == _Basis.detached)
              LabeledTextField(
                label: 'Revision',
                controller: TextEditingController(text: _commitish ?? ''),
                placeholder: 'a commit, tag, or branch',
                onChanged: () {},
              ),

            const SizedBox(height: 12),
            _locationField(context, problem),

            const SizedBox(height: 14),
            Container(height: 1, color: MacosColors.separatorColor),
            const SizedBox(height: 12),

            _copyIgnoredField(context),
            const SizedBox(height: 10),
            _postCreateField(context),

            const SizedBox(height: 12),
            Row(
              children: [
                MacosCheckbox(
                  value: _openAfter,
                  onChanged: (v) => setState(() => _openAfter = v),
                ),
                const SizedBox(width: 8),
                const Text('Open it when done'),
              ],
            ),

            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                PushButton(
                  controlSize: ControlSize.large,
                  secondary: true,
                  onPressed: _submitting
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                PushButton(
                  controlSize: ControlSize.large,
                  onPressed: _valid && problem == null && !_submitting
                      ? _submit
                      : null,
                  child: Text(_submitting ? 'Creating…' : 'Create Worktree'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _basisPicker(BuildContext context, List<GitRef> locals) {
    // A branch already checked out somewhere cannot be checked out again — git
    // refuses, and there is no override. Rather than let the user pick it and
    // then hand them git's error, take it off the menu and say why.
    final available = locals.where((b) => b.worktreePath == null).toList();
    final taken = locals.where((b) => b.worktreePath != null).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Based on',
          style: MacosTheme.of(context).typography.caption1.copyWith(
            color: MacosColors.systemGrayColor,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            for (final (basis, label) in const [
              (_Basis.newBranch, 'New branch'),
              (_Basis.existingBranch, 'Existing branch'),
              (_Basis.detached, 'Detached'),
            ]) ...[
              PushButton(
                controlSize: ControlSize.regular,
                secondary: _basis != basis,
                onPressed: () => setState(() {
                  _basis = basis;
                  _syncLocation();
                }),
                child: Text(label),
              ),
              const SizedBox(width: 6),
            ],
          ],
        ),
        if (_basis == _Basis.existingBranch) ...[
          const SizedBox(height: 8),
          MacosPopupButton<String>(
            value: _existingBranch,
            hint: const Text('Choose a branch'),
            items: [
              for (final b in available)
                MacosPopupMenuItem(
                  value: b.shortName,
                  child: Text(b.shortName),
                ),
            ],
            onChanged: (v) => setState(() {
              _existingBranch = v;
              _syncLocation();
            }),
          ),
          if (taken > 0)
            FieldHint(
              '$taken branch${taken == 1 ? ' is' : 'es are'} already checked '
              'out in another worktree and cannot be used here.',
            ),
        ],
      ],
    );
  }

  Widget _locationField(BuildContext context, String? problem) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Location',
          style: MacosTheme.of(context).typography.caption1.copyWith(
            color: MacosColors.systemGrayColor,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: MacosTextField(
                controller: _location,
                placeholder: '/path/to/myapp-feature',
                decoration: kAppTextFieldDecoration,
                focusedDecoration: kAppTextFieldFocusedDecoration,
                placeholderStyle: kAppPlaceholderStyle,
                onChanged: (_) => setState(() => _locationEdited = true),
              ),
            ),
            const SizedBox(width: 6),
            PushButton(
              controlSize: ControlSize.regular,
              secondary: true,
              onPressed: _pickLocation,
              child: const Text('Choose…'),
            ),
          ],
        ),
        if (problem != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              problem,
              style: MacosTheme.of(context).typography.caption1.copyWith(
                color: MacosColors.systemRedColor,
              ),
            ),
          )
        else if (ref.read(connectionProvider).isLocal && _grantedParent == null)
          const FieldHint(
            'macOS will ask you to choose the destination folder — that is how '
            'the app is granted permission to create the worktree there.',
          ),
      ],
    );
  }

  Widget _copyIgnoredField(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            MacosCheckbox(
              value: _copyIgnored,
              onChanged: (v) => setState(() => _copyIgnored = v),
            ),
            const SizedBox(width: 8),
            const Text('Copy ignored files'),
          ],
        ),
        if (_copyIgnored) ...[
          const SizedBox(height: 6),
          MacosTextField(
            controller: _copyGlobs,
            placeholder: '.env*, .env.local',
            decoration: kAppTextFieldDecoration,
            focusedDecoration: kAppTextFieldFocusedDecoration,
            placeholderStyle: kAppPlaceholderStyle,
          ),
          const FieldHint(
            'git checks out tracked files only, so a new worktree has no .env '
            'and the project fails on first run. These patterns are copied '
            'across. Comma-separated.',
          ),
        ],
      ],
    );
  }

  Widget _postCreateField(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            MacosCheckbox(
              value: _runPostCreate,
              onChanged: (v) => setState(() => _runPostCreate = v),
            ),
            const SizedBox(width: 8),
            const Text('Run a command after creating'),
          ],
        ),
        if (_runPostCreate) ...[
          const SizedBox(height: 6),
          MacosTextField(
            controller: _postCreate,
            placeholder: 'pnpm install',
            decoration: kAppTextFieldDecoration,
            focusedDecoration: kAppTextFieldFocusedDecoration,
            placeholderStyle: kAppPlaceholderStyle,
          ),
          const FieldHint(
            'Runs inside the new worktree. Output appears in the Output view.',
          ),
        ],
      ],
    );
  }
}
